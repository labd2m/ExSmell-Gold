```elixir
defmodule Devices.Registry do
  @moduledoc """
  Maintains a registry of connected IoT devices indexed by device ID.
  Device state (last seen, reported metrics) is held in a shared ETS table
  owned by this GenServer. All write operations go through the server
  to serialize mutations; reads are served directly from ETS for low latency.
  """

  use GenServer

  @table :device_registry

  @type device_id :: String.t()
  @type device_state :: %{
          id: device_id(),
          firmware: String.t(),
          last_seen_at: DateTime.t(),
          metrics: map()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers or updates a device's state from a heartbeat payload."
  @spec heartbeat(device_id(), map()) :: :ok
  def heartbeat(device_id, payload)
      when is_binary(device_id) and is_map(payload) do
    GenServer.cast(__MODULE__, {:heartbeat, device_id, payload})
  end

  @doc "Returns the current state for a device, or an error if unknown."
  @spec lookup(device_id()) :: {:ok, device_state()} | {:error, :not_found}
  def lookup(device_id) when is_binary(device_id) do
    case :ets.lookup(@table, device_id) do
      [] -> {:error, :not_found}
      [{^device_id, state}] -> {:ok, state}
    end
  end

  @doc "Returns the IDs of all devices seen within the last N seconds."
  @spec active_since(pos_integer()) :: [device_id()]
  def active_since(seconds) when is_integer(seconds) and seconds > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -seconds, :second)
    :ets.tab2list(@table)
    |> Enum.filter(fn {_id, state} ->
      DateTime.compare(state.last_seen_at, cutoff) in [:gt, :eq]
    end)
    |> Enum.map(fn {id, _state} -> id end)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast({:heartbeat, device_id, payload}, state) do
    device_state = %{
      id: device_id,
      firmware: Map.get(payload, "firmware", "unknown"),
      last_seen_at: DateTime.utc_now(),
      metrics: Map.get(payload, "metrics", %{})
    }
    :ets.insert(@table, {device_id, device_state})
    {:noreply, state}
  end
end

defmodule Devices.AlertEvaluator do
  @moduledoc """
  Evaluates metric thresholds for a device state and returns a list
  of triggered alert descriptors. Thresholds are provided by the caller
  as a plain map to keep this module stateless and testable.
  """

  alias Devices.Registry

  @type threshold_map :: %{required(String.t()) => {number(), :above | :below}}
  @type alert :: %{metric: String.t(), value: number(), threshold: number(), direction: atom()}

  @doc "Evaluates thresholds against the current device metrics."
  @spec evaluate(String.t(), threshold_map()) ::
          {:ok, [alert()]} | {:error, :not_found}
  def evaluate(device_id, thresholds)
      when is_binary(device_id) and is_map(thresholds) do
    with {:ok, device} <- Registry.lookup(device_id) do
      alerts = check_thresholds(device.metrics, thresholds)
      {:ok, alerts}
    end
  end

  defp check_thresholds(metrics, thresholds) do
    Enum.flat_map(thresholds, fn {metric, {threshold, direction}} ->
      case Map.get(metrics, metric) do
        nil -> []
        value -> maybe_alert(metric, value, threshold, direction)
      end
    end)
  end

  defp maybe_alert(metric, value, threshold, :above) when value > threshold,
    do: [%{metric: metric, value: value, threshold: threshold, direction: :above}]
  defp maybe_alert(metric, value, threshold, :below) when value < threshold,
    do: [%{metric: metric, value: value, threshold: threshold, direction: :below}]
  defp maybe_alert(_metric, _value, _threshold, _direction), do: []
end
```
