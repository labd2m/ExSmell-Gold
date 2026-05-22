```elixir
defmodule Scheduling.TimeUtils do
  @moduledoc """
  Date/time arithmetic helpers used across the scheduling subsystem.
  """

  def next_occurrence_after(datetime, interval_seconds) do
    DateTime.add(datetime, interval_seconds, :second)
  end

  def seconds_until(target_datetime) do
    DateTime.diff(target_datetime, DateTime.utc_now(), :second)
  end

  def format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  def format_duration(seconds) when seconds < 3600 do
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end
  def format_duration(seconds) do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    s = rem(seconds, 60)
    "#{h}h #{m}m #{s}s"
  end

  def within_window?(datetime, start_time, end_time) do
    time = DateTime.to_time(datetime)
    Time.compare(time, start_time) in [:gt, :eq] and
      Time.compare(time, end_time) in [:lt, :eq]
  end
end

defmodule Scheduling.CronHelpers do
  @moduledoc """
  Cron-expression utilities and job-schedule computation helpers,
  shared across scheduling modules via `use`.
  """

  defmacro __using__(_opts) do
    quote do
      import Scheduling.TimeUtils  # propagates time utilities into every caller

      def parse_interval(expr) do
        case expr do
          "@hourly"  -> {:ok, 3_600}
          "@daily"   -> {:ok, 86_400}
          "@weekly"  -> {:ok, 604_800}
          "@monthly" -> {:ok, 2_592_000}
          _ ->
            case Integer.parse(expr) do
              {n, "s"} when n > 0 -> {:ok, n}
              {n, "m"} when n > 0 -> {:ok, n * 60}
              {n, "h"} when n > 0 -> {:ok, n * 3600}
              _                   -> {:error, {:invalid_interval, expr}}
            end
        end
      end

      def next_run_at(last_run_at, interval_expr) do
        with {:ok, interval_s} <- parse_interval(interval_expr) do
          {:ok, next_occurrence_after(last_run_at, interval_s)}
        end
      end

      def overdue?(job) do
        case job.next_run_at do
          nil  -> false
          time -> DateTime.compare(time, DateTime.utc_now()) == :lt
        end
      end

      def describe_schedule(interval_expr) do
        case parse_interval(interval_expr) do
          {:ok, secs}      -> "Every #{format_duration(secs)}"
          {:error, reason} -> "Invalid schedule: #{inspect(reason)}"
        end
      end
    end
  end
end

defmodule Scheduling.JobDispatcher do
  @moduledoc """
  Manages recurring job definitions, tracks run history, determines which
  jobs are due, and issues dispatch commands to worker queues.
  """

  use Scheduling.CronHelpers

  @max_retry_attempts 5
  @default_timeout_s  300

  def register(registry, job_spec) do
    with {:ok, _} <- validate_job(job_spec) do
      job = %{
        id:               job_id(),
        name:             job_spec.name,
        module:           job_spec.module,
        function:         job_spec.function,
        args:             job_spec.args || [],
        interval:         job_spec.interval,
        timeout_s:        job_spec[:timeout_s] || @default_timeout_s,
        max_retries:      job_spec[:max_retries] || @max_retry_attempts,
        retry_count:      0,
        last_run_at:      nil,
        next_run_at:      nil,
        status:           :idle,
        created_at:       DateTime.utc_now()
      }

      {:ok, Map.put(registry, job.id, job)}
    end
  end

  def due_jobs(registry) do
    registry
    |> Map.values()
    |> Enum.filter(&overdue?/1)
    |> Enum.sort_by(& &1.next_run_at)
  end

  def mark_dispatched(registry, job_id) do
    case Map.fetch(registry, job_id) do
      {:ok, job} ->
        now = DateTime.utc_now()
        {:ok, next} = next_run_at(now, job.interval)

        updated = %{job |
          last_run_at:  now,
          next_run_at:  next,
          status:       :running,
          retry_count:  0
        }

        {:ok, Map.put(registry, job_id, updated)}

      :error -> {:error, :job_not_found}
    end
  end

  def record_success(registry, job_id) do
    update_job(registry, job_id, fn job ->
      %{job | status: :idle, retry_count: 0}
    end)
  end

  def record_failure(registry, job_id, reason) do
    update_job(registry, job_id, fn job ->
      if job.retry_count + 1 >= job.max_retries do
        %{job | status: :failed, retry_count: job.retry_count + 1}
      else
        %{job | status: :idle, retry_count: job.retry_count + 1}
      end
    end)
  end

  def job_summary(registry) do
    Enum.map(registry, fn {id, job} ->
      %{
        id:       id,
        name:     job.name,
        schedule: describe_schedule(job.interval),
        status:   job.status,
        overdue:  overdue?(job)
      }
    end)
  end

  defp validate_job(%{name: n, module: m, function: f, interval: i})
       when is_binary(n) and is_atom(m) and is_atom(f) and is_binary(i) do
    parse_interval(i)
  end

  defp validate_job(_), do: {:error, :invalid_job_spec}

  defp update_job(registry, job_id, fun) do
    case Map.fetch(registry, job_id) do
      {:ok, job} -> {:ok, Map.put(registry, job_id, fun.(job))}
      :error     -> {:error, :job_not_found}
    end
  end

  defp job_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false) |> then(&"job_#{&1}")
  end
end
```
