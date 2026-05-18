# Annotated Example — Code Smell

## Metadata

- **Smell name:** Dynamic atom creation
- **Expected smell location:** `resolve_queue_name/1` function
- **Affected function(s):** `resolve_queue_name/1`
- **Short explanation:** The function converts a queue name string received from a scheduling API configuration payload into an atom using `String.to_atom/1`. Queue names are determined at runtime by the configuration data returned from an external service, making this an uncontrolled source of atoms.

---

```elixir
defmodule Scheduling.JobDispatcher do
  @moduledoc """
  Dispatches scheduled jobs to the appropriate background queue.
  Queue routing is determined by job metadata fetched from the scheduling API.
  """

  require Logger

  alias Scheduling.{SchedulerClient, JobRegistry, QueueBackend, RateLimiter}

  @dispatch_timeout_ms 5_000
  @default_queue :default

  @spec dispatch_pending() :: {:ok, map()} | {:error, term()}
  def dispatch_pending do
    Logger.info("Dispatching pending scheduled jobs")

    case SchedulerClient.fetch_due_jobs() do
      {:ok, jobs} ->
        results = Enum.map(jobs, &dispatch_one/1)

        stats = Enum.reduce(results, %{ok: 0, failed: 0}, fn
          {:ok, _}, acc -> Map.update!(acc, :ok, &(&1 + 1))
          {:error, _}, acc -> Map.update!(acc, :failed, &(&1 + 1))
        end)

        Logger.info("Dispatch cycle complete", stats: inspect(stats))
        {:ok, stats}

      {:error, reason} ->
        Logger.error("Failed to fetch due jobs", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp dispatch_one(%{"job_id" => job_id} = job_spec) do
    Logger.debug("Dispatching job", job_id: job_id)

    with {:ok, queue} <- resolve_queue_name(job_spec["queue"]),
         :ok <- RateLimiter.check(queue),
         {:ok, handler} <- JobRegistry.resolve_handler(job_spec["job_type"]),
         {:ok, payload} <- build_payload(job_spec),
         {:ok, ref} <- QueueBackend.enqueue(queue, handler, payload,
                         timeout: @dispatch_timeout_ms) do
      Logger.debug("Job enqueued", job_id: job_id, queue: queue, ref: ref)
      {:ok, ref}
    else
      {:error, :rate_limited} ->
        Logger.warning("Rate limited, skipping job", job_id: job_id)
        {:error, :rate_limited}

      {:error, reason} ->
        Logger.error("Job dispatch failed", job_id: job_id, reason: inspect(reason))
        {:error, reason}
    end
  end

  defp dispatch_one(invalid) do
    Logger.error("Invalid job spec", spec: inspect(invalid))
    {:error, :invalid_job_spec}
  end

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is applied to a
  # queue name string originating from the scheduling API's response payload.
  # If the API introduces new queue names, or returns varied/misspelled values,
  # each unique string creates a new permanent atom. The developer has no
  # control over how many distinct queue names may appear over the system's
  # lifetime.
  defp resolve_queue_name(nil), do: {:ok, @default_queue}

  defp resolve_queue_name(name) when is_binary(name) do
    queue = String.to_atom(name)
    {:ok, queue}
  end
  # VALIDATION: SMELL END

  defp resolve_queue_name(_), do: {:error, :invalid_queue_name}

  defp build_payload(%{"job_id" => job_id, "args" => args, "scheduled_at" => scheduled_at}) do
    {:ok,
     %{
       job_id: job_id,
       args: args || %{},
       scheduled_at: scheduled_at,
       dispatched_at: DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end

  defp build_payload(_), do: {:error, :malformed_job_spec}
end
```
