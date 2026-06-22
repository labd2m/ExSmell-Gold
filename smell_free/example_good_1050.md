```elixir
defmodule IoT.Sensors.ReadingAggregator do
  @moduledoc """
  Aggregates time-windowed sensor readings from a fleet of IoT devices.
  Readings are grouped by sensor ID and summarized with statistical metrics.
  This module is purely functional; it performs no I/O or process interactions.
  """

  alias IoT.Sensors.{Reading, SensorSummary}

  @type window_opts :: [window_seconds: pos_integer(), min_readings: non_neg_integer()]

  @doc """
  Groups `readings` into per-sensor summaries within the given time window.

  Options:
  - `:window_seconds` — size of the time window in seconds (default: 60)
  - `:min_readings` — minimum readings required to include a sensor (default: 1)
  """
  @spec aggregate([Reading.t()], window_opts()) :: [SensorSummary.t()]
  def aggregate(readings, opts \\ []) when is_list(readings) do
    window = Keyword.get(opts, :window_seconds, 60)
    min_readings = Keyword.get(opts, :min_readings, 1)
    cutoff = System.system_time(:second) - window

    readings
    |> Enum.filter(&within_window?(&1, cutoff))
    |> Enum.group_by(& &1.sensor_id)
    |> Enum.map(fn {sensor_id, sensor_readings} ->
      build_summary(sensor_id, sensor_readings)
    end)
    |> Enum.filter(&(&1.reading_count >= min_readings))
    |> Enum.sort_by(& &1.sensor_id)
  end

  @doc "Returns the most recent reading across all provided readings."
  @spec latest([ Reading.t()]) :: {:ok, Reading.t()} | {:error, :empty}
  def latest([]), do: {:error, :empty}

  def latest(readings) when is_list(readings) do
    latest = Enum.max_by(readings, & &1.recorded_at, DateTime)
    {:ok, latest}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec within_window?(Reading.t(), integer()) :: boolean()
  defp within_window?(%Reading{recorded_at: dt}, cutoff) do
    DateTime.to_unix(dt) >= cutoff
  end

  @spec build_summary(String.t(), [Reading.t()]) :: SensorSummary.t()
  defp build_summary(sensor_id, readings) do
    values = Enum.map(readings, & &1.value)

    %SensorSummary{
      sensor_id: sensor_id,
      reading_count: length(values),
      min_value: Enum.min(values),
      max_value: Enum.max(values),
      mean_value: mean(values),
      latest_reading_at: latest_timestamp(readings)
    }
  end

  @spec mean([number()]) :: float()
  defp mean(values) do
    Enum.sum(values) / length(values)
  end

  @spec latest_timestamp([Reading.t()]) :: DateTime.t()
  defp latest_timestamp(readings) do
    readings
    |> Enum.max_by(& &1.recorded_at, DateTime)
    |> Map.fetch!(:recorded_at)
  end
end

defmodule IoT.Sensors.Reading do
  @moduledoc "A single timestamped sensor reading."

  @enforce_keys [:sensor_id, :value, :recorded_at]
  defstruct [:sensor_id, :value, :recorded_at, :unit]

  @type t :: %__MODULE__{
          sensor_id: String.t(),
          value: number(),
          recorded_at: DateTime.t(),
          unit: String.t() | nil
        }
end

defmodule IoT.Sensors.SensorSummary do
  @moduledoc "Statistical summary of readings for a single sensor."

  defstruct [:sensor_id, :reading_count, :min_value, :max_value, :mean_value, :latest_reading_at]

  @type t :: %__MODULE__{
          sensor_id: String.t(),
          reading_count: non_neg_integer(),
          min_value: number(),
          max_value: number(),
          mean_value: float(),
          latest_reading_at: DateTime.t()
        }
end
```
