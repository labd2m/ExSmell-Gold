```elixir
defmodule Etl.UserEnrichmentPipeline do
  @moduledoc """
  Enrichment pipeline that reads raw user records, fetches supplemental
  data from external sources in parallel, and writes the merged output.
  Uses `Task.async_stream` for bounded concurrency during the enrichment stage.
  """

  alias Etl.UserEnrichmentPipeline.{Fetcher, Merger, Writer}

  @type raw_user :: %{id: String.t(), email: String.t(), name: String.t()}
  @type enriched_user :: %{
          id: String.t(),
          email: String.t(),
          name: String.t(),
          company: String.t() | nil,
          country: String.t() | nil,
          plan: String.t() | nil
        }

  @type pipeline_result :: %{
          processed: non_neg_integer(),
          enriched: non_neg_integer(),
          failed: non_neg_integer(),
          duration_ms: non_neg_integer()
        }

  @spec run([raw_user()], keyword()) :: {:ok, pipeline_result()} | {:error, String.t()}
  def run(users, opts \\ []) when is_list(users) do
    concurrency = Keyword.get(opts, :concurrency, 10)
    timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)
    start = System.monotonic_time(:millisecond)

    with :ok <- validate_input(users) do
      results =
        users
        |> Task.async_stream(
          &Fetcher.enrich(&1, timeout_ms: timeout_ms),
          max_concurrency: concurrency,
          timeout: timeout_ms + 1_000,
          on_timeout: :kill_task
        )
        |> Stream.map(&unwrap_task_result/1)
        |> Enum.to_list()

      {enriched, failed} = partition_results(results)

      with :ok <- Writer.write_all(enriched) do
        duration = System.monotonic_time(:millisecond) - start

        report = %{
          processed: length(users),
          enriched: length(enriched),
          failed: length(failed),
          duration_ms: duration
        }

        emit_telemetry(report)
        {:ok, report}
      end
    end
  end

  @spec validate_input([raw_user()]) :: :ok | {:error, String.t()}
  defp validate_input([]), do: {:error, "input list is empty"}
  defp validate_input(_), do: :ok

  @spec unwrap_task_result({:ok, term()} | {:exit, term()}) ::
          {:ok, enriched_user()} | {:error, String.t()}
  defp unwrap_task_result({:ok, result}), do: result
  defp unwrap_task_result({:exit, :timeout}), do: {:error, "enrichment timed out"}
  defp unwrap_task_result({:exit, reason}), do: {:error, "enrichment crashed: #{inspect(reason)}"}

  @spec partition_results([{:ok, enriched_user()} | {:error, String.t()}]) ::
          {[enriched_user()], [String.t()]}
  defp partition_results(results) do
    Enum.reduce(results, {[], []}, fn
      {:ok, user}, {ok, err} -> {[user | ok], err}
      {:error, reason}, {ok, err} -> {ok, [reason | err]}
    end)
  end

  @spec emit_telemetry(pipeline_result()) :: :ok
  defp emit_telemetry(report) do
    :telemetry.execute(
      [:etl, :enrichment_pipeline, :complete],
      %{processed: report.processed, enriched: report.enriched, failed: report.failed},
      %{duration_ms: report.duration_ms}
    )
  end
end

defmodule Etl.UserEnrichmentPipeline.Fetcher do
  @moduledoc """
  Fetches supplemental enrichment data for a single user from
  external lookup APIs. Tolerates partial failures by substituting
  nil for any unavailable field.
  """

  alias Etl.UserEnrichmentPipeline.{CompanyLookup, GeoLookup, PlanLookup}

  @spec enrich(map(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def enrich(%{id: id, email: email, name: name} = _user, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 5_000)

    company = resolve_silently(fn -> CompanyLookup.by_email(email, timeout: timeout) end)
    country = resolve_silently(fn -> GeoLookup.by_email(email, timeout: timeout) end)
    plan = resolve_silently(fn -> PlanLookup.by_user_id(id, timeout: timeout) end)

    {:ok, %{id: id, email: email, name: name, company: company, country: country, plan: plan}}
  end

  @spec resolve_silently((() -> {:ok, String.t()} | {:error, term()})) :: String.t() | nil
  defp resolve_silently(lookup_fn) do
    case lookup_fn.() do
      {:ok, value} when is_binary(value) -> value
      _ -> nil
    end
  rescue
    _ -> nil
  end
end

defmodule Etl.UserEnrichmentPipeline.Merger do
  @moduledoc "Merges a base user map with an enrichment result map."

  @spec merge(map(), map()) :: map()
  def merge(base, enrichment) when is_map(base) and is_map(enrichment) do
    Map.merge(base, enrichment)
  end
end

defmodule Etl.UserEnrichmentPipeline.Writer do
  @moduledoc "Persists a list of enriched user maps to the destination store."

  alias Etl.Repo
  alias Etl.EnrichedUser

  @spec write_all([map()]) :: :ok | {:error, String.t()}
  def write_all(users) when is_list(users) do
    Repo.transaction(fn ->
      Enum.each(users, fn user ->
        case Repo.insert(EnrichedUser.changeset(%EnrichedUser{}, user)) do
          {:ok, _} -> :ok
          {:error, changeset} -> Repo.rollback("insert failed: #{inspect(changeset.errors)}")
        end
      end)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
```
