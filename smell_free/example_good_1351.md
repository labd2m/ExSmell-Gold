```elixir
defmodule Metrics.Counter do
  @moduledoc """
  Maintains named integer counters in a shared ETS table.
  All increments are atomic via `:ets.update_counter/3`.
  Counters are partitioned by namespace to prevent key collisions.
  """

  @table :metrics_counters

  @spec ensure_started() :: :ok
  def ensure_started do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    end
    :ok
  end

  @spec increment(String.t(), String.t(), pos_integer()) :: non_neg_integer()
  def increment(namespace, name, amount \\ 1)
      when is_binary(namespace) and is_binary(name) and is_integer(amount) and amount > 0 do
    key = build_key(namespace, name)
    :ets.update_counter(@table, key, {2, amount}, {key, 0})
  end

  @spec reset(String.t(), String.t()) :: :ok
  def reset(namespace, name) when is_binary(namespace) and is_binary(name) do
    :ets.insert(@table, {build_key(namespace, name), 0})
    :ok
  end

  @spec value(String.t(), String.t()) :: non_neg_integer()
  def value(namespace, name) when is_binary(namespace) and is_binary(name) do
    case :ets.lookup(@table, build_key(namespace, name)) do
      [{_key, count}] -> count
      [] -> 0
    end
  end

  @spec all_in_namespace(String.t()) :: %{String.t() => non_neg_integer()}
  def all_in_namespace(namespace) when is_binary(namespace) do
    prefix = "#{namespace}."

    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {key, _} -> String.starts_with?(key, prefix) end)
    |> Map.new(fn {key, count} -> {String.replace_prefix(key, prefix, ""), count} end)
  end

  defp build_key(namespace, name), do: "#{namespace}.#{name}"
end

defmodule Metrics.Reporter do
  @moduledoc """
  Periodically snapshots all registered counters and emits the data
  via `:telemetry` events for downstream consumers such as StatsD or
  Prometheus exporters. The report interval is configurable at startup.
  """

  use GenServer

  require Logger

  alias Metrics.Counter

  @default_interval_ms 15_000

  @type config :: %{interval_ms: pos_integer(), namespace: String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    namespace = Keyword.get(opts, :namespace, "app")
    Counter.ensure_started()
    schedule_report(interval)
    {:ok, %{interval_ms: interval, namespace: namespace}}
  end

  @impl GenServer
  def handle_call(:flush, _from, %{namespace: ns} = state) do
    emit_snapshot(ns)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:report, %{interval_ms: interval, namespace: ns} = state) do
    emit_snapshot(ns)
    schedule_report(interval)
    {:noreply, state}
  end

  defp emit_snapshot(namespace) do
    counts = Counter.all_in_namespace(namespace)

    Enum.each(counts, fn {name, value} ->
      :telemetry.execute(
        [:metrics, :counter, :snapshot],
        %{value: value},
        %{namespace: namespace, name: name}
      )
    end)

    Logger.debug("Metrics snapshot emitted", namespace: namespace, counter_count: map_size(counts))
  end

  defp schedule_report(interval) do
    Process.send_after(self(), :report, interval)
  end
end
```
