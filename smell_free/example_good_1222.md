```elixir
defmodule Health.Check do
  @moduledoc """
  A struct representing the outcome of a single system health probe.
  """

  @enforce_keys [:name, :status]
  defstruct [:name, :status, :latency_ms, :message, :checked_at]

  @type status :: :healthy | :degraded | :unhealthy

  @type t :: %__MODULE__{
          name: atom(),
          status: status(),
          latency_ms: non_neg_integer() | nil,
          message: String.t() | nil,
          checked_at: DateTime.t()
        }

  @spec ok(atom(), non_neg_integer()) :: t()
  def ok(name, latency_ms) when is_atom(name) and is_integer(latency_ms) do
    %__MODULE__{name: name, status: :healthy, latency_ms: latency_ms, checked_at: DateTime.utc_now()}
  end

  @spec degraded(atom(), String.t()) :: t()
  def degraded(name, message) when is_atom(name) and is_binary(message) do
    %__MODULE__{name: name, status: :degraded, message: message, checked_at: DateTime.utc_now()}
  end

  @spec fail(atom(), String.t()) :: t()
  def fail(name, message) when is_atom(name) and is_binary(message) do
    %__MODULE__{name: name, status: :unhealthy, message: message, checked_at: DateTime.utc_now()}
  end
end

defmodule Health.Aggregator do
  @moduledoc """
  Runs all registered health checks concurrently and returns an aggregated
  system status. The overall status is the worst individual status observed.
  """

  alias Health.Check

  @type probe :: {atom(), (-> Check.t())}
  @type report :: %{status: Check.status(), checks: list(Check.t()), checked_at: DateTime.t()}

  @probe_timeout_ms 5_000

  @spec run(list(probe())) :: report()
  def run(probes) when is_list(probes) do
    checks =
      probes
      |> Task.async_stream(
        fn {name, probe_fn} -> run_probe(name, probe_fn) end,
        timeout: @probe_timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.map(&unwrap_task_result/1)

    %{status: aggregate_status(checks), checks: checks, checked_at: DateTime.utc_now()}
  end

  @spec to_http_status(report()) :: 200 | 503
  def to_http_status(%{status: :healthy}), do: 200
  def to_http_status(%{status: _}), do: 503

  defp run_probe(name, probe_fn) do
    start = System.monotonic_time(:millisecond)

    try do
      result = probe_fn.()
      latency = System.monotonic_time(:millisecond) - start
      %{result | latency_ms: result.latency_ms || latency}
    rescue
      err -> Check.fail(name, Exception.message(err))
    end
  end

  defp unwrap_task_result({:ok, check}), do: check
  defp unwrap_task_result({:exit, :timeout}), do: Check.fail(:unknown, "probe timed out")
  defp unwrap_task_result({:exit, reason}), do: Check.fail(:unknown, "probe exited: #{inspect(reason)}")

  defp aggregate_status(checks) do
    cond do
      Enum.any?(checks, &(&1.status == :unhealthy)) -> :unhealthy
      Enum.any?(checks, &(&1.status == :degraded)) -> :degraded
      true -> :healthy
    end
  end
end

defmodule Health.StandardProbes do
  @moduledoc """
  Pre-built probe functions for common dependencies.
  """

  alias Health.Check

  @spec database(atom()) :: (-> Check.t())
  def database(repo) when is_atom(repo) do
    fn ->
      start = System.monotonic_time(:millisecond)

      try do
        repo.query!("SELECT 1")
        latency = System.monotonic_time(:millisecond) - start
        Check.ok(:database, latency)
      rescue
        err -> Check.fail(:database, Exception.message(err))
      end
    end
  end

  @spec memory(non_neg_integer()) :: (-> Check.t())
  def memory(warn_threshold_mb \\ 1_500) when is_integer(warn_threshold_mb) do
    fn ->
      used_mb = :erlang.memory(:total) |> div(1_048_576)

      if used_mb < warn_threshold_mb do
        Check.ok(:memory, 0)
      else
        Check.degraded(:memory, "memory usage #{used_mb} MB exceeds threshold #{warn_threshold_mb} MB")
      end
    end
  end
end
```
