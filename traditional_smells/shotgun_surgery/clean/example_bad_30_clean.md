```elixir
defmodule IoT.SensorParser do
  @moduledoc """
  Decodes raw binary payloads received from IoT devices into structured
  sensor reading maps with typed values and units.
  """


  @spec parse_reading(atom(), binary()) :: {:ok, map()} | {:error, term()}
  def parse_reading(:temperature, <<value::float-32, _rest::binary>>) do
    celsius = Float.round(value, 2)
    {:ok, %{type: :temperature, value: celsius, unit: unit_label(:temperature)}}
  end

  def parse_reading(:humidity, <<value::float-32, _rest::binary>>) do
    percent = Float.round(value, 2) |> min(100.0) |> max(0.0)
    {:ok, %{type: :humidity, value: percent, unit: unit_label(:humidity)}}
  end

  def parse_reading(:pressure, <<value::float-32, _rest::binary>>) do
    hpa = Float.round(value, 1)
    {:ok, %{type: :pressure, value: hpa, unit: unit_label(:pressure)}}
  end

  def parse_reading(type, _payload) do
    {:error, {:unknown_sensor_type, type}}
  end

  @spec unit_label(atom()) :: String.t()
  def unit_label(:temperature), do: "°C"
  def unit_label(:humidity),    do: "%"
  def unit_label(:pressure),    do: "hPa"


  def parse_batch(sensor_type, payloads) do
    payloads
    |> Enum.map(&parse_reading(sensor_type, &1))
    |> Enum.split_with(&match?({:ok, _}, &1))
    |> then(fn {ok, err} ->
      {:ok, Enum.map(ok, &elem(&1, 1)), Enum.map(err, &elem(&1, 1))}
    end)
  end
end

defmodule IoT.AlertEngine do
  @moduledoc """
  Evaluates sensor readings against configurable thresholds and emits
  alerts when values exceed safe operational bounds.
  """


  @spec alert_threshold(atom()) :: {float(), float()}
  def alert_threshold(:temperature), do: {-10.0, 85.0}
  def alert_threshold(:humidity),    do: {20.0, 90.0}
  def alert_threshold(:pressure),    do: {950.0, 1050.0}

  @spec severity(atom(), float()) :: atom()
  def severity(:temperature, value) when value > 90.0 or value < -15.0, do: :critical
  def severity(:temperature, value) when value > 85.0 or value < -10.0, do: :warning
  def severity(:temperature, _),                                          do: :normal

  def severity(:humidity, value) when value > 95.0 or value < 10.0, do: :critical
  def severity(:humidity, value) when value > 90.0 or value < 20.0, do: :warning
  def severity(:humidity, _),                                         do: :normal

  def severity(:pressure, value) when value > 1060.0 or value < 930.0, do: :critical
  def severity(:pressure, value) when value > 1050.0 or value < 950.0, do: :warning
  def severity(:pressure, _),                                            do: :normal


  def evaluate(reading) do
    {min_val, max_val} = alert_threshold(reading.type)
    level = severity(reading.type, reading.value)

    cond do
      level == :critical ->
        {:alert, :critical, build_alert(reading, min_val, max_val)}

      level == :warning ->
        {:alert, :warning, build_alert(reading, min_val, max_val)}

      true ->
        :ok
    end
  end

  defp build_alert(reading, min_val, max_val) do
    %{
      sensor_id:   reading.sensor_id,
      type:        reading.type,
      value:       reading.value,
      unit:        IoT.SensorParser.unit_label(reading.type),
      safe_range:  {min_val, max_val},
      triggered_at: DateTime.utc_now()
    }
  end
end

defmodule IoT.SensorDashboard do
  @moduledoc """
  Provides configuration for time-series aggregation and chart rendering
  of sensor data within the operational monitoring dashboard.
  """


  @spec aggregation_window_seconds(atom()) :: pos_integer()
  def aggregation_window_seconds(:temperature), do: 300
  def aggregation_window_seconds(:humidity),    do: 300
  def aggregation_window_seconds(:pressure),    do: 60

  @spec display_chart_type(atom()) :: atom()
  def display_chart_type(:temperature), do: :line
  def display_chart_type(:humidity),    do: :area
  def display_chart_type(:pressure),    do: :line


  def widget_config(sensor_type) do
    {min_threshold, max_threshold} = IoT.AlertEngine.alert_threshold(sensor_type)

    %{
      sensor_type:  sensor_type,
      unit:         IoT.SensorParser.unit_label(sensor_type),
      chart_type:   display_chart_type(sensor_type),
      window_secs:  aggregation_window_seconds(sensor_type),
      y_axis_min:   min_threshold - 10,
      y_axis_max:   max_threshold + 10,
      refresh_ms:   aggregation_window_seconds(sensor_type) * 1_000
    }
  end
end
```
