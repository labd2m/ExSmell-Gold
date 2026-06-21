```elixir
defmodule Telemetry.MetricsSampler do
  @moduledoc """
  Periodically samples VM and application metrics and emits them as
  telemetry events. Metrics include memory usage, process count, scheduler
  utilisation, and custom application gauges registered at runtime. Each
  sample is a self-contained event with measurement and metadata maps so
  downstream handlers can store, aggregate, or forward with no coupling
  to this module.
  """

  use GenServer

  require Logger

  @type gauge_name :: atom()
  @type gauge_fn :: (-> number())
  @type sample_interval_ms :: pos_integer()

  @default_sample_interval_ms 10_000
  @vm_metrics_event [:my_app, :vm, :metrics]
  @custom_metrics_event [:my_app, :custom, :metrics]

  @doc "Starts the sampler. Accepts `interval_ms` to override the default sample rate."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers a named gauge function. The function is called on every sample cycle."
  @spec register_gauge(gauge_name(), gauge_fn()) :: :ok
  def register_gauge(name, fun) when is_atom(name) and is_function(fun, 0) do
    GenServer.cast(__MODULE__, {:register_gauge, name, fun})
  end

  @doc "Removes a previously registered gauge."
  @spec deregister_gauge(gauge_name()) :: :ok
  def deregister_gauge(name) when is_atom(name) do
    GenServer.cast(__MODULE__, {:deregister_gauge, name})
  end

  @doc "Returns the names of all currently registered gauges."
  @spec registered_gauges() :: [gauge_name()]
  def registered_gauges, do: GenServer.call(__MODULE__, :registered_gauges)

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_sample_interval_ms)
    Process.send_after(self(), :sample, interval)
    {:ok, %{interval: interval, gauges: %{}}}
  end

  @impl GenServer
  def handle_cast({:register_gauge, name, fun}, state) do
    {:noreply, put_in(state, [:gauges, name], fun)}
  end

  def handle_cast({:deregister_gauge, name}, state) do
    {:noreply, update_in(state, [:gauges], &Map.delete(&1, name))}
  end

  @impl GenServer
  def handle_call(:registered_gauges, _from, state) do
    {:reply, Map.keys(state.gauges), state}
  end

  @impl GenServer
  def handle_info(:sample, state) do
    emit_vm_metrics()
    emit_custom_metrics(state.gauges)
    Process.send_after(self(), :sample, state.interval)
    {:noreply, state}
  end

  defp emit_vm_metrics do
    mem = :erlang.memory()

    measurements = %{
      total_memory_bytes: mem[:total],
      process_memory_bytes: mem[:processes],
      atom_memory_bytes: mem[:atom],
      binary_memory_bytes: mem[:binary],
      process_count: :erlang.system_info(:process_count),
      port_count: :erlang.system_info(:port_count),
      run_queue_lengths: :erlang.statistics(:run_queue_lengths_all) |> Enum.sum()
    }

    :telemetry.execute(@vm_metrics_event, measurements, %{node: node()})
  end

  defp emit_custom_metrics(gauges) when map_size(gauges) == 0, do: :ok

  defp emit_custom_metrics(gauges) do
    measurements =
      Map.new(gauges, fn {name, fun} ->
        value =
          try do
            fun.()
          rescue
            _ -> nil
          end

        {name, value}
      end)
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    :telemetry.execute(@custom_metrics_event, measurements, %{node: node()})
  end
end
```
