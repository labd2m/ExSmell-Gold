```elixir
defmodule Devices.Reading do
  @moduledoc """
  A single telemetry reading emitted by an IoT device.
  """

  @type t :: %__MODULE__{
          device_id: String.t(),
          metric: atom(),
          value: float(),
          unit: String.t(),
          recorded_at: DateTime.t()
        }

  defstruct [:device_id, :metric, :value, :unit, :recorded_at]
end

defmodule Devices.ThresholdPolicy do
  @moduledoc """
  Defines acceptable value ranges for device metrics.
  Readings outside the range generate an alert.
  """

  @type t :: %__MODULE__{
          metric: atom(),
          min: float() | nil,
          max: float() | nil,
          severity: :warning | :critical
        }

  defstruct [:metric, :min, :max, severity: :warning]

  @spec violated?(%__MODULE__{}, float()) :: boolean()
  def violated?(%__MODULE__{min: min, max: max}, value) do
    below_min = not is_nil(min) and value < min
    above_max = not is_nil(max) and value > max
    below_min or above_max
  end
end

defmodule Devices.AlertEngine do
  use GenServer

  alias Devices.{Reading, ThresholdPolicy}

  @moduledoc """
  Evaluates incoming device telemetry readings against configured
  threshold policies and dispatches alerts for any violations.
  Alert handlers are pluggable and injected at startup.
  """

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ingest(Reading.t()) :: :ok
  def ingest(%Reading{} = reading) do
    GenServer.cast(__MODULE__, {:ingest, reading})
  end

  @spec register_policy(ThresholdPolicy.t()) :: :ok
  def register_policy(%ThresholdPolicy{} = policy) do
    GenServer.cast(__MODULE__, {:register_policy, policy})
  end

  @impl GenServer
  def init(opts) do
    alert_handler = Keyword.fetch!(opts, :alert_handler)
    {:ok, %{policies: %{}, alert_handler: alert_handler}}
  end

  @impl GenServer
  def handle_cast({:register_policy, policy}, state) do
    {:noreply, put_in(state.policies[policy.metric], policy)}
  end

  def handle_cast({:ingest, reading}, state) do
    case Map.fetch(state.policies, reading.metric) do
      :error ->
        {:noreply, state}

      {:ok, policy} ->
        if ThresholdPolicy.violated?(policy, reading.value) do
          alert = build_alert(reading, policy)
          Task.start(fn -> state.alert_handler.dispatch(alert) end)
        end

        {:noreply, state}
    end
  end

  defp build_alert(%Reading{} = reading, %ThresholdPolicy{} = policy) do
    %{
      device_id: reading.device_id,
      metric: reading.metric,
      value: reading.value,
      unit: reading.unit,
      severity: policy.severity,
      threshold_min: policy.min,
      threshold_max: policy.max,
      recorded_at: reading.recorded_at,
      alerted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end
end
```
