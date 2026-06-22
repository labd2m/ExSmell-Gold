```elixir
defmodule Platform.AutoScaler do
  @moduledoc """
  A GenServer that monitors a workload metric and dynamically adjusts the
  number of worker processes in a `DynamicSupervisor` to match demand.

  Scale-up is triggered when utilization exceeds the high watermark;
  scale-down removes idle workers when utilization drops below the low
  watermark. Both watermarks and check intervals are configurable.
  """

  use GenServer

  require Logger

  @type worker_spec :: Supervisor.child_spec() | {module(), keyword()}
  @type metric_fn :: (-> float())

  @default_check_interval_ms :timer.seconds(10)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns the current number of managed workers."
  @spec worker_count(GenServer.server()) :: non_neg_integer()
  def worker_count(server \\ __MODULE__), do: GenServer.call(server, :worker_count)

  @doc "Returns the most recently sampled utilization value."
  @spec current_utilization(GenServer.server()) :: float() | nil
  def current_utilization(server \\ __MODULE__), do: GenServer.call(server, :utilization)

  @impl GenServer
  def init(opts) do
    state = %{
      supervisor: Keyword.fetch!(opts, :supervisor),
      worker_spec: Keyword.fetch!(opts, :worker_spec),
      metric_fn: Keyword.fetch!(opts, :metric_fn),
      min_workers: Keyword.get(opts, :min_workers, 1),
      max_workers: Keyword.get(opts, :max_workers, 10),
      high_watermark: Keyword.get(opts, :high_watermark, 0.8),
      low_watermark: Keyword.get(opts, :low_watermark, 0.3),
      check_interval_ms: Keyword.get(opts, :check_interval_ms, @default_check_interval_ms),
      utilization: nil
    }

    initial_count = state.min_workers
    Enum.each(1..initial_count, fn _ -> start_worker(state) end)

    schedule_check(state.check_interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:worker_count, _from, %{supervisor: sup} = state) do
    count = DynamicSupervisor.count_children(sup).active
    {:reply, count, state}
  end

  @impl GenServer
  def handle_call(:utilization, _from, state) do
    {:reply, state.utilization, state}
  end

  @impl GenServer
  def handle_info(:check, state) do
    utilization = state.metric_fn.()
    new_state = %{state | utilization: utilization}

    current = DynamicSupervisor.count_children(state.supervisor).active
    target = compute_target(utilization, current, new_state)
    adjusted_state = adjust_workers(new_state, current, target)

    schedule_check(state.check_interval_ms)
    {:noreply, adjusted_state}
  end

  defp compute_target(utilization, current, %{high_watermark: high, low_watermark: low, min_workers: min, max_workers: max}) do
    cond do
      utilization > high -> min(current + ceil(current * 0.5), max)
      utilization < low -> max(current - 1, min)
      true -> current
    end
  end

  defp adjust_workers(state, current, target) when target > current do
    count = target - current
    Logger.info("[AutoScaler] Scaling up", adding: count, utilization: state.utilization)
    Enum.each(1..count, fn _ -> start_worker(state) end)
    state
  end

  defp adjust_workers(state, current, target) when target < current do
    count = current - target
    Logger.info("[AutoScaler] Scaling down", removing: count, utilization: state.utilization)
    remove_workers(state.supervisor, count)
    state
  end

  defp adjust_workers(state, _current, _target), do: state

  defp start_worker(%{supervisor: sup, worker_spec: spec}) do
    DynamicSupervisor.start_child(sup, spec)
  end

  defp remove_workers(sup, count) do
    sup
    |> DynamicSupervisor.which_children()
    |> Enum.take(count)
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(sup, pid)
    end)
  end

  defp schedule_check(interval), do: Process.send_after(self(), :check, interval)
end
```
