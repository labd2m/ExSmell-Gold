# Annotated Example – Unnecessary Macros

| Field | Value |
|---|---|
| **Smell name** | Unnecessary macros |
| **Expected smell location** | `Scheduling.CronHelper` module, `next_run_at/2` macro |
| **Affected function(s)** | `next_run_at/2` |
| **Short explanation** | `next_run_at/2` adds a job-interval duration to a runtime `DateTime`. This is arithmetic on runtime values; no compile-time expansion is involved. A plain function would be idiomatic and readable without requiring callers to `require` the module. |

```elixir
defmodule Scheduling.CronHelper do
  @moduledoc """
  Utilities for computing run schedules, detecting missed executions,
  and formatting job metadata for the background job dashboard.
  """

  @intervals %{
    minutely: 60,
    hourly: 3_600,
    daily: 86_400,
    weekly: 604_800
  }

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because `next_run_at/2` uses `DateTime.add/3`
  # on a runtime `DateTime` and a runtime integer. Both values are determined
  # at runtime, so `defmacro` contributes nothing over `def`. The macro forces
  # every caller to issue a `require` directive and adds needless `quote/unquote`
  # indirection where a simple function call would suffice.
  defmacro next_run_at(last_run_at, interval_seconds) do
    quote do
      DateTime.add(unquote(last_run_at), unquote(interval_seconds), :second)
    end
  end
  # VALIDATION: SMELL END

  def interval_seconds(name) when is_atom(name) do
    Map.get(@intervals, name) ||
      raise ArgumentError, "Unknown interval: #{name}"
  end

  def interval_seconds(seconds) when is_integer(seconds) and seconds > 0, do: seconds

  def build_schedule(job, last_run_at \\ nil) do
    require Scheduling.CronHelper

    secs = interval_seconds(job.interval)
    base = last_run_at || DateTime.utc_now()

    next = Scheduling.CronHelper.next_run_at(base, secs)

    %{
      job_id: job.id,
      name: job.name,
      interval: job.interval,
      last_run_at: last_run_at,
      next_run_at: next,
      interval_seconds: secs
    }
  end

  def overdue?(job) do
    require Scheduling.CronHelper

    secs = interval_seconds(job.interval)
    next = Scheduling.CronHelper.next_run_at(job.last_run_at, secs)
    DateTime.compare(DateTime.utc_now(), next) == :gt
  end

  def missed_runs(job, since) do
    require Scheduling.CronHelper

    secs = interval_seconds(job.interval)
    now = DateTime.utc_now()

    Stream.iterate(since, fn dt ->
      Scheduling.CronHelper.next_run_at(dt, secs)
    end)
    |> Stream.take_while(fn dt -> DateTime.compare(dt, now) != :gt end)
    |> Enum.to_list()
    |> Enum.drop(1)
  end

  def upcoming_runs(job, count) do
    require Scheduling.CronHelper

    secs = interval_seconds(job.interval)
    base = job.last_run_at || DateTime.utc_now()

    Enum.scan(1..count, base, fn _, prev ->
      Scheduling.CronHelper.next_run_at(prev, secs)
    end)
  end

  def seconds_until_next_run(job) do
    require Scheduling.CronHelper

    secs = interval_seconds(job.interval)
    next = Scheduling.CronHelper.next_run_at(job.last_run_at, secs)
    max(DateTime.diff(next, DateTime.utc_now(), :second), 0)
  end

  def format_schedule(schedule) do
    """
    Job      : #{schedule.name}
    Interval : #{schedule.interval} (#{schedule.interval_seconds}s)
    Last run : #{schedule.last_run_at || "never"}
    Next run : #{schedule.next_run_at}
    """
  end
end
```
