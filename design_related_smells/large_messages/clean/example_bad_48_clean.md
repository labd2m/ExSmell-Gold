```elixir
defmodule SensorAnalyser do
  use GenServer
  require Logger

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{alerts: [], processed_batches: 0}, opts)
  end

  def alert_count(pid), do: GenServer.call(pid, :alert_count)

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:alert_count, _from, state) do
    {:reply, length(state.alerts), state}
  end

  @impl true
  def handle_cast({:sensor_batch, cluster_id, readings}, state) do
    Logger.info("SensorAnalyser: processing #{length(readings)} readings from cluster=#{cluster_id}")

    new_alerts =
      readings
      |> Enum.filter(&anomalous?/1)
      |> Enum.map(fn r ->
        %{sensor_id: r.sensor_id, cluster_id: cluster_id, value: r.channels.ch1, detected_at: DateTime.utc_now()}
      end)

    {:noreply, %{state |
      alerts: new_alerts ++ state.alerts,
      processed_batches: state.processed_batches + 1
    }}
  end

  @impl true
  def handle_cast(_msg, state), do: {:noreply, state}

  defp anomalous?(reading), do: reading.channels.ch1 > 950 or reading.channels.temperature > 85.0
end

defmodule SensorCollector do
  require Logger

  @poll_interval_ms 5_000

  @doc """
  Polls all sensors in the given device cluster, collects the current
  readings, and forwards the full batch to the analyser for threshold
  checking and anomaly detection.
  """
  def forward_readings(analyser_pid, cluster_id) do
    Logger.info("SensorCollector: polling cluster=#{cluster_id}")

    readings = poll_cluster(cluster_id)

    Logger.info("SensorCollector: #{length(readings)} readings collected — sending to analyser")

    GenServer.cast(analyser_pid, {:sensor_batch, cluster_id, readings})

    Process.sleep(@poll_interval_ms)
    forward_readings(analyser_pid, cluster_id)
  end

  # ---------------------------------------------------------------------------
  # Private helpers — simulate polling a large sensor cluster
  # ---------------------------------------------------------------------------

  defp poll_cluster(cluster_id) do
    Enum.map(1..30_000, fn n ->
      sensor_id = "SENS-#{cluster_id}-#{String.pad_leading(Integer.to_string(n), 6, "0")}"

      %{
        sensor_id: sensor_id,
        cluster_id: cluster_id,
        type: Enum.random([:pressure, :temperature, :vibration, :flow, :humidity]),
        channels: %{
          ch1: :rand.uniform(1_000),
          ch2: :rand.uniform(1_000),
          ch3: :rand.uniform(1_000),
          temperature: 20.0 + :rand.uniform() * 80,
          voltage: 3.2 + :rand.uniform() * 1.5
        },
        calibration: %{
          offset: :rand.uniform() * 0.05,
          gain: 1.0 + :rand.uniform() * 0.01,
          last_calibrated_at: ~U[2024-01-01 00:00:00Z]
        },
        quality: %{
          snr_db: 20 + :rand.uniform(40),
          error_count: :rand.uniform(5),
          status: Enum.random([:ok, :degraded, :fault])
        },
        sampled_at: DateTime.utc_now()
      }
    end)
  end
end
```
