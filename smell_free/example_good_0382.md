```elixir
defmodule Observability.HealthCheck do
  @moduledoc """
  A supervised GenServer that periodically probes registered health checks
  and caches the results. Each check is an async `Task` so a slow or
  hanging dependency cannot block the others. Results are readable
  synchronously by the health endpoint without triggering a live probe
  on every request, keeping `/healthz` latency predictable under load.
  """

  use GenServer

  require Logger

  @type check_name :: atom()
  @type check_fn :: (() -> :ok | {:ok, map()} | {:error, term()})
  @type check_status :: :passing | :degraded | :failing | :unknown
  @type check_result :: %{
          name: check_name(),
          status: check_status(),
          detail: map() | nil,
          checked_at: DateTime.t()
        }

  @probe_interval_ms 30_000
  @probe_timeout_ms 5_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a named health check function. The function must return
  `:ok`, `{:ok, detail_map}`, or `{:error, reason}`.
  """
  @spec register(check_name(), check_fn()) :: :ok
  def register(name, fun) when is_atom(name) and is_function(fun, 0) do
    GenServer.cast(__MODULE__, {:register, name, fun})
  end

  @doc """
  Returns a map of the most recent check results, keyed by check name.
  Never triggers live probes; always returns the cached state.
  """
  @spec results() :: %{check_name() => check_result()}
  def results do
    GenServer.call(__MODULE__, :results)
  end

  @doc """
  Returns the overall system status: `:passing` if all checks pass,
  `:degraded` if any are degraded, `:failing` if any are failing.
  """
  @spec overall_status() :: check_status()
  def overall_status do
    results()
    |> Map.values()
    |> derive_overall_status()
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    schedule_probe()
    {:ok, %{checks: %{}, results: %{}}}
  end

  @impl GenServer
  def handle_cast({:register, name, fun}, state) do
    new_state = put_in(state, [:checks, name], fun)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_call(:results, _from, state) do
    {:reply, state.results, state}
  end

  @impl GenServer
  def handle_info(:probe, state) do
    updated_results = run_all_probes(state.checks)
    schedule_probe()
    {:noreply, %{state | results: updated_results}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp run_all_probes(checks) do
    checks
    |> Task.async_stream(
      fn {name, fun} -> {name, run_probe(fun)} end,
      timeout: @probe_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {name, result}}, acc -> Map.put(acc, name, result)
      {:exit, :timeout}, acc -> acc
    end)
  end

  defp run_probe(fun) do
    result =
      try do
        fun.()
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end

    build_result(result)
  end

  defp build_result(:ok), do: %{status: :passing, detail: nil, checked_at: DateTime.utc_now()}
  defp build_result({:ok, detail}), do: %{status: :passing, detail: detail, checked_at: DateTime.utc_now()}
  defp build_result({:degraded, detail}), do: %{status: :degraded, detail: detail, checked_at: DateTime.utc_now()}
  defp build_result({:error, reason}), do: %{status: :failing, detail: %{reason: inspect(reason)}, checked_at: DateTime.utc_now()}

  defp derive_overall_status([]), do: :unknown

  defp derive_overall_status(results) do
    statuses = Enum.map(results, & &1.status)

    cond do
      :failing in statuses -> :failing
      :degraded in statuses -> :degraded
      Enum.all?(statuses, &(&1 == :passing)) -> :passing
      true -> :unknown
    end
  end

  defp schedule_probe do
    Process.send_after(self(), :probe, @probe_interval_ms)
  end
end
```
