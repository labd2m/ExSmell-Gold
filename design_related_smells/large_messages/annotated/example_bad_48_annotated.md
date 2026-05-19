# Annotated Example – Bad Code (Human Validation)

## Metadata

- **Smell name:** Large messages
- **Expected smell location:** `SensorCollector.forward_readings/2` — the `GenServer.cast/2` that sends the full list of sensor reading structs to the analyser process
- **Affected function(s):** `SensorCollector.forward_readings/2`, `SensorAnalyser.handle_cast/2`
- **Short explanation:** A full poll cycle of sensor readings — thousands of maps per device cluster, each with multi-channel measurement arrays — is copied into the analyser process as one `GenServer.cast` message. Because collection cycles are frequent and device clusters can be numerous, this produces repeated large-message copies that degrade scheduler responsiveness across the node.

---

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

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because the entire poll-cycle batch —
    # up to 30 000 sensor reading maps per cluster, each containing multi-
    # channel measurement arrays, calibration coefficients, and quality
    # metrics — is deep-copied into the SensorAnalyser process heap as a
    # single GenServer.cast message. With a 5-second poll interval and
    # dozens of clusters, the node is continuously processing large copies,
    # blocking each collector process during transmission and starving other
    # processes of scheduler time.
    GenServer.cast(analyser_pid, {:sensor_batch, cluster_id, readings})
    # VALIDATION: SMELL END

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
