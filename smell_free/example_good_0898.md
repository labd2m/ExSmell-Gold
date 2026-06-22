```elixir
defmodule Metrics.Bucket do
  @moduledoc false

  @type kind :: :counter | :gauge | :histogram

  @type t :: %__MODULE__{
          name: String.t(),
          kind: kind(),
          value: number(),
          samples: [number()],
          labels: map(),
          updated_at: integer()
        }

  defstruct [:name, :kind, :labels, value: 0, samples: [], updated_at: 0]
end

defmodule Metrics.Aggregator do
  @moduledoc """
  Attaches to application telemetry events and accumulates measurements
  into in-memory metric buckets suitable for a `/metrics` dashboard endpoint.

  Counters accumulate monotonically. Gauges track the latest observed value.
  Histograms collect raw samples so callers can compute percentiles on demand.
  All bucket reads go directly to ETS for lock-free concurrency; mutations
  are serialised through the GenServer to prevent concurrent write races.
  """

  use GenServer

  alias Metrics.Bucket

  @table __MODULE__

  @type event_spec :: %{
          required(:event) => [atom()],
          required(:measurements) => [atom()],
          required(:kind) => Bucket.kind(),
          optional(:labels_from) => [atom()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec attach([event_spec()]) :: :ok
  def attach(event_specs) when is_list(event_specs) do
    Enum.each(event_specs, fn spec ->
      :telemetry.attach(
        handler_id(spec.event),
        spec.event,
        &handle_event/4,
        spec
      )
    end)
  end

  @spec snapshot() :: [Bucket.t()]
  def snapshot do
    :ets.tab2list(@table) |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.name)
  end

  @spec snapshot_as_map() :: map()
  def snapshot_as_map do
    Map.new(snapshot(), fn bucket ->
      stats = compute_stats(bucket)
      {bucket.name, Map.put(stats, :labels, bucket.labels)}
    end)
  end

  @spec percentile(String.t(), float()) :: float() | nil
  def percentile(metric_name, p) when p >= 0.0 and p <= 1.0 do
    case :ets.lookup(@table, metric_name) do
      [{^metric_name, %Bucket{samples: []}}] -> nil
      [{^metric_name, %Bucket{samples: samples}}] ->
        sorted = Enum.sort(samples)
        idx = max(0, round(p * length(sorted)) - 1)
        Enum.at(sorted, idx)
      [] -> nil
    end
  end

  @spec reset(String.t()) :: :ok
  def reset(metric_name) when is_binary(metric_name) do
    GenServer.call(__MODULE__, {:reset, metric_name})
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:update, name, kind, value, labels}, _from, state) do
    now = System.system_time(:millisecond)

    bucket =
      case :ets.lookup(@table, name) do
        [{^name, existing}] -> existing
        [] -> %Bucket{name: name, kind: kind, labels: labels}
      end

    updated = apply_measurement(bucket, kind, value, now)
    :ets.insert(@table, {name, updated})
    {:reply, :ok, state}
  end

  def handle_call({:reset, name}, _from, state) do
    :ets.delete(@table, name)
    {:reply, :ok, state}
  end

  defp handle_event(event_name, measurements, metadata, spec) do
    Enum.each(spec.measurements, fn measure ->
      case Map.fetch(measurements, measure) do
        {:ok, value} when is_number(value) ->
          name = Enum.join(event_name ++ [measure], ".")
          labels = extract_labels(metadata, Map.get(spec, :labels_from, []))
          GenServer.call(__MODULE__, {:update, name, spec.kind, value, labels})

        _ -> :ok
      end
    end)
  end

  defp apply_measurement(bucket, :counter, value, now) do
    %{bucket | value: bucket.value + value, updated_at: now}
  end

  defp apply_measurement(bucket, :gauge, value, now) do
    %{bucket | value: value, updated_at: now}
  end

  defp apply_measurement(bucket, :histogram, value, now) do
    trimmed = Enum.take([value | bucket.samples], 10_000)
    %{bucket | samples: trimmed, value: value, updated_at: now}
  end

  defp extract_labels(metadata, keys) do
    Map.take(metadata, keys)
  end

  defp compute_stats(%Bucket{kind: :histogram, samples: samples}) when samples != [] do
    sorted = Enum.sort(samples)
    count = length(sorted)
    sum = Enum.sum(sorted)
    %{count: count, sum: sum, mean: sum / count,
      p50: Enum.at(sorted, div(count, 2)),
      p95: Enum.at(sorted, round(count * 0.95) - 1 |> max(0)),
      p99: Enum.at(sorted, round(count * 0.99) - 1 |> max(0))}
  end

  defp compute_stats(%Bucket{kind: kind, value: value}) do
    %{kind: kind, value: value}
  end

  defp handler_id(event_name) do
    "metrics_aggregator:" <> Enum.join(event_name, ".")
  end
end
```
