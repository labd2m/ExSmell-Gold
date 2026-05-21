# Annotated Example — Bad Code

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro schedule_job/2` inside `MyApp.Scheduling.JobDSL`
- **Affected function(s):** `schedule_job/2` macro
- **Short explanation:** Every call to `schedule_job/2` causes the Elixir compiler to expand a large `quote` block that performs name validation, cron expression checks, timezone validation, worker module checks, concurrency option guards, deduplication logic, and struct construction inline. This entire block should be delegated to a plain function, with the macro only emitting a lightweight function call.

---

```elixir
defmodule MyApp.Scheduling.JobDSL do
  @moduledoc """
  DSL for registering recurring background jobs in a scheduler module.

  Example:

      defmodule MyApp.Scheduling.NightlyJobs do
        use MyApp.Scheduling.JobDSL

        schedule_job :cleanup_expired_sessions,
          cron:        "0 2 * * *",
          worker:      MyApp.Workers.SessionCleanup,
          timezone:    "America/Sao_Paulo",
          max_retries: 3

        schedule_job :send_daily_digest,
          cron:        "0 8 * * *",
          worker:      MyApp.Workers.DailyDigest,
          timezone:    "America/Sao_Paulo",
          overlap:     false
      end
  """

  defmacro __using__(_opts) do
    quote do
      import MyApp.Scheduling.JobDSL, only: [schedule_job: 2]
      Module.register_attribute(__MODULE__, :scheduled_jobs, accumulate: true)
      @before_compile MyApp.Scheduling.JobDSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def scheduled_jobs, do: @scheduled_jobs

      def job(name) do
        Enum.find(@scheduled_jobs, fn j -> j.name == name end)
      end
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because each invocation of schedule_job/2
  # VALIDATION: expands the entire validation and registration pipeline inline:
  # VALIDATION: atom-name check, cron-string format check, timezone string
  # VALIDATION: check, worker module existence and callback verification,
  # VALIDATION: numeric options guards, boolean guards, deduplication check,
  # VALIDATION: and struct construction. A scheduler module with many jobs
  # VALIDATION: compiles this entire block at each call site instead of once
  # VALIDATION: inside a shared helper function.
  defmacro schedule_job(name, opts) do
    quote do
      name = unquote(name)
      opts = unquote(opts)

      unless is_atom(name) do
        raise ArgumentError,
              "schedule_job/2: name must be an atom, got #{inspect(name)}"
      end

      cron = Keyword.fetch!(opts, :cron)

      unless is_binary(cron) do
        raise ArgumentError,
              "schedule_job/2: :cron must be a binary cron expression, got #{inspect(cron)}"
      end

      cron_parts = String.split(cron, " ")

      unless length(cron_parts) == 5 do
        raise ArgumentError,
              "schedule_job/2: :cron must have exactly 5 fields, got #{inspect(cron)}"
      end

      timezone = Keyword.get(opts, :timezone, "UTC")

      unless is_binary(timezone) and byte_size(timezone) > 0 do
        raise ArgumentError,
              "schedule_job/2: :timezone must be a non-empty string, got #{inspect(timezone)}"
      end

      worker = Keyword.fetch!(opts, :worker)

      unless is_atom(worker) do
        raise ArgumentError,
              "schedule_job/2: :worker must be a module atom, got #{inspect(worker)}"
      end

      :ok = Code.ensure_compiled!(worker)

      unless function_exported?(worker, :perform, 1) do
        raise ArgumentError,
              "schedule_job/2: worker #{inspect(worker)} must export perform/1"
      end

      max_retries = Keyword.get(opts, :max_retries, 0)

      unless is_integer(max_retries) and max_retries >= 0 do
        raise ArgumentError,
              "schedule_job/2: :max_retries must be a non-negative integer, " <>
                "got #{inspect(max_retries)}"
      end

      overlap = Keyword.get(opts, :overlap, true)

      unless is_boolean(overlap) do
        raise ArgumentError,
              "schedule_job/2: :overlap must be a boolean, got #{inspect(overlap)}"
      end

      existing = Module.get_attribute(__MODULE__, :scheduled_jobs)

      if Enum.any?(existing, fn j -> j.name == name end) do
        raise ArgumentError,
              "schedule_job/2: duplicate job name #{inspect(name)} in #{inspect(__MODULE__)}"
      end

      job = %{
        name:        name,
        cron:        cron,
        timezone:    timezone,
        worker:      worker,
        max_retries: max_retries,
        overlap:     overlap
      }

      @scheduled_jobs job
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Returns all jobs whose cron expression would fire within the next `minutes`
  minutes from `now`.
  """
  @spec due_soon(module(), DateTime.t(), pos_integer()) :: [map()]
  def due_soon(scheduler_module, now, minutes \\ 60) do
    scheduler_module.scheduled_jobs()
    |> Enum.filter(fn job ->
      next = next_run(job.cron, now)
      diff = DateTime.diff(next, now, :minute)
      diff >= 0 and diff <= minutes
    end)
  end

  defp next_run(_cron, now) do
    # Simplified stub; in production this would parse the cron expression.
    DateTime.add(now, 3600, :second)
  end
end
```
