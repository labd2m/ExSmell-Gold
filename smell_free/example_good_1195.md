```elixir
defmodule Health.CheckAggregator do
  @moduledoc """
  Runs a registered set of named health checks concurrently and aggregates
  the results into a single system health report. Each check has an
  independent timeout so a slow dependency cannot block the full report.
  """

  @type check_name :: atom()
  @type check_fn :: (-> :ok | {:error, String.t()})

  @type check_result :: %{
          name: check_name(),
          status: :healthy | :degraded | :unhealthy,
          latency_ms: non_neg_integer(),
          detail: String.t() | nil
        }

  @type report :: %{
          status: :healthy | :degraded | :unhealthy,
          checks: [check_result()],
          generated_at: DateTime.t()
        }

  @default_timeout_ms 5_000

  @spec run([{check_name(), check_fn()}], keyword()) :: report()
  def run(checks, opts \\ []) when is_list(checks) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    results =
      checks
      |> Task.async_stream(
        fn {name, fun} -> {name, timed_check(fun)} end,
        max_concurrency: length(checks),
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.map(&extract_result/1)

    %{
      status: aggregate_status(results),
      checks: results,
      generated_at: DateTime.utc_now()
    }
  end

  @spec register_check(check_name(), check_fn()) :: :ok
  def register_check(name, fun) when is_atom(name) and is_function(fun, 0) do
    :persistent_term.put({__MODULE__, name}, fun)
  end

  @spec run_registered(keyword()) :: report()
  def run_registered(opts \\ []) do
    checks =
      :persistent_term.get()
      |> Enum.filter(fn {{mod, _name}, _} -> mod == __MODULE__ end)
      |> Enum.map(fn {{_, name}, fun} -> {name, fun} end)

    run(checks, opts)
  end

  @spec timed_check(check_fn()) :: {non_neg_integer(), :ok | {:error, String.t()}}
  defp timed_check(fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    elapsed = System.monotonic_time(:millisecond) - start
    {elapsed, result}
  end

  @spec extract_result({:ok, {check_name(), {non_neg_integer(), :ok | {:error, String.t()}}}} | {:exit, term()}) ::
          check_result()
  defp extract_result({:ok, {name, {latency, :ok}}}) do
    %{name: name, status: :healthy, latency_ms: latency, detail: nil}
  end

  defp extract_result({:ok, {name, {latency, {:error, detail}}}}) do
    %{name: name, status: :unhealthy, latency_ms: latency, detail: detail}
  end

  defp extract_result({:exit, {name, _reason}}) do
    %{name: name, status: :unhealthy, latency_ms: 0, detail: "check timed out or crashed"}
  end

  defp extract_result({:exit, _}) do
    %{name: :unknown, status: :unhealthy, latency_ms: 0, detail: "check process exited"}
  end

  @spec aggregate_status([check_result()]) :: :healthy | :degraded | :unhealthy
  defp aggregate_status(results) do
    statuses = Enum.map(results, & &1.status)

    cond do
      Enum.all?(statuses, &(&1 == :healthy)) -> :healthy
      Enum.any?(statuses, &(&1 == :unhealthy)) -> :unhealthy
      true -> :degraded
    end
  end
end
```
