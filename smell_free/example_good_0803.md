```elixir
defmodule MyApp.Ops.AnomalyDetector do
  @moduledoc """
  Detects statistical anomalies in time-series metric streams using a
  rolling Z-score model. A data point is flagged as anomalous when its
  deviation from the rolling mean exceeds a configurable number of
  standard deviations. Detected anomalies are broadcast over PubSub
  and written to the `anomaly_events` table for investigation.

  Start this module under the application supervisor:

      children = [MyApp.Ops.AnomalyDetector]
  """

  use GenServer

  require Logger

  alias MyApp.Repo
  alias MyApp.Ops.AnomalyEvent

  @pubsub MyApp.PubSub
  @topic "ops:anomalies"
  @default_window 60
  @default_threshold 3.0

  @type metric_name :: String.t()
  @type window_state :: %{values: [float()], window: pos_integer()}

  @doc "Starts the anomaly detector."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a new data point for `metric` and checks for anomaly.
  Returns `{:ok, :normal}` or `{:ok, :anomaly, z_score}`.
  """
  @spec record(metric_name(), float()) :: {:ok, :normal} | {:ok, :anomaly, float()}
  def record(metric, value) when is_binary(metric) and is_number(value) do
    GenServer.call(__MODULE__, {:record, metric, value * 1.0})
  end

  @doc "Subscribes the caller to anomaly notifications."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @impl GenServer
  def init(opts) do
    state = %{
      windows: %{},
      window_size: Keyword.get(opts, :window, @default_window),
      threshold: Keyword.get(opts, :threshold, @default_threshold)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:record, metric, value}, _from, state) do
    window = Map.get(state.windows, metric, %{values: [], window: state.window_size})
    updated_window = push_value(window, value)
    new_state = %{state | windows: Map.put(state.windows, metric, updated_window)}

    result = evaluate(metric, value, updated_window, state.threshold)
    {:reply, result, new_state}
  end

  @spec push_value(window_state(), float()) :: window_state()
  defp push_value(%{values: values, window: window}, new_value) do
    trimmed = Enum.take([new_value | values], window)
    %{values: trimmed, window: window}
  end

  @spec evaluate(metric_name(), float(), window_state(), float()) ::
          {:ok, :normal} | {:ok, :anomaly, float()}
  defp evaluate(_metric, _value, %{values: values}, _threshold)
       when length(values) < 10 do
    {:ok, :normal}
  end

  defp evaluate(metric, value, %{values: values}, threshold) do
    mean = Enum.sum(values) / length(values)
    variance = Enum.sum_by(values, fn v -> (v - mean) ** 2 end) / length(values)
    std = :math.sqrt(variance)

    z_score =
      if std > 0.0, do: abs(value - mean) / std, else: 0.0

    if z_score >= threshold do
      handle_anomaly(metric, value, z_score, mean, std)
      {:ok, :anomaly, Float.round(z_score, 3)}
    else
      {:ok, :normal}
    end
  end

  @spec handle_anomaly(metric_name(), float(), float(), float(), float()) :: :ok
  defp handle_anomaly(metric, value, z_score, mean, std) do
    Logger.warning("anomaly_detected",
      metric: metric,
      value: value,
      z_score: z_score,
      mean: mean,
      std: std
    )

    %AnomalyEvent{}
    |> AnomalyEvent.changeset(%{
      metric: metric,
      value: value,
      z_score: z_score,
      rolling_mean: mean,
      rolling_std: std,
      detected_at: DateTime.utc_now()
    })
    |> Repo.insert()

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:anomaly_detected, %{
      metric: metric,
      value: value,
      z_score: z_score
    }})

    :ok
  end
end
```
