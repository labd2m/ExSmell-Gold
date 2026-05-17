# Annotated Example — Speculative Assumptions

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `Telemetry.SensorParser.decode_frame/1`, around the binary pattern matching with loose guards
- **Affected function(s):** `decode_frame/1`
- **Short explanation:** The function uses `binary_part/3` to extract fixed-width fields from a raw binary sensor frame without first checking that the binary is at least as long as required. `binary_part/3` raises `ArgumentError` for out-of-bounds access, so a short frame crashes — but the function wraps everything in a `rescue` and returns `{:error, :parse_error}` *silently*, discarding partial readings. A more subtle issue is that `binary_part` with a negative or miscomputed offset silently extracts data from the wrong position when the frame header byte indicates a subtype with a different layout, causing readings to be numerically plausible but wrong.

---

```elixir
defmodule Telemetry.SensorParser do
  @moduledoc """
  Decodes binary telemetry frames transmitted by IoT environmental sensors
  over MQTT. Each frame carries temperature, humidity, pressure, battery level,
  and a device identifier.

  Frame layout (fixed, 20 bytes):
    Bytes 0-1:   Frame type (0xAB 0xCD for standard environmental frame)
    Bytes 2-7:   Device ID (ASCII)
    Byte  8:     Sequence number (uint8)
    Bytes 9-10:  Temperature in centi-Celsius (int16, big-endian)
    Bytes 11-12: Humidity in centi-percent (uint16, big-endian)
    Bytes 13-15: Pressure in Pascal (uint24, big-endian)
    Byte  16:    Battery level (0-100, uint8)
    Bytes 17-19: Reserved / checksum
  """

  require Logger

  @frame_type_standard 0xABCD
  @frame_type_extended 0xABCE

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because the function checks the frame type marker
  # VALIDATION: and then uses binary_part/3 with the same fixed offsets regardless
  # VALIDATION: of whether the frame is "standard" or "extended". The extended frame
  # VALIDATION: type (0xABCE) has a different layout — the device ID is 10 bytes, not 6,
  # VALIDATION: shifting all subsequent fields. The function does not account for this
  # VALIDATION: and silently extracts temperature from what is actually part of the
  # VALIDATION: extended device ID field. No crash occurs; the result is a plausible-
  # VALIDATION: looking reading (temperature, humidity, pressure all parse to numeric
  # VALIDATION: values) that is entirely wrong. The system records false sensor data
  # VALIDATION: with full confidence and no indication of the layout mismatch.
  def decode_frame(<<type::16, rest::binary>>) do
    frame_type = type

    device_id   = binary_part(rest, 0, 6) |> String.trim_trailing(<<0>>)
    seq         = :binary.decode_unsigned(binary_part(rest, 6, 1))
    temp_raw    = :binary.decode_unsigned(binary_part(rest, 7, 2), :big)
    humid_raw   = :binary.decode_unsigned(binary_part(rest, 9, 2), :big)
    pressure_b  = binary_part(rest, 11, 3)
    battery     = :binary.decode_unsigned(binary_part(rest, 14, 1))

    temperature = decode_signed16(temp_raw) / 100.0
    humidity    = humid_raw / 100.0
    pressure    = decode_uint24(pressure_b)

    reading = %{
      frame_type:  frame_type,
      device_id:   device_id,
      sequence:    seq,
      temperature: temperature,
      humidity:    humidity,
      pressure:    pressure,
      battery_pct: battery,
      received_at: DateTime.utc_now()
    }

    {:ok, reading}
  rescue
    _ ->
      {:error, :parse_error}
  end
  # VALIDATION: SMELL END

  def decode_frame(_), do: {:error, :invalid_frame}

  defp decode_signed16(n) when n >= 0x8000, do: n - 0x10000
  defp decode_signed16(n), do: n

  defp decode_uint24(<<a, b, c>>), do: a * 65536 + b * 256 + c
  defp decode_uint24(_), do: 0

  def process_batch(frames) when is_list(frames) do
    frames
    |> Enum.map(&decode_frame/1)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, r} -> r end)
  end

  def aggregate(readings) do
    count = length(readings)

    if count == 0 do
      %{count: 0, avg_temp: nil, avg_humidity: nil, avg_pressure: nil}
    else
      %{
        count:        count,
        avg_temp:     avg(readings, :temperature),
        avg_humidity: avg(readings, :humidity),
        avg_pressure: avg(readings, :pressure),
        min_battery:  readings |> Enum.map(& &1.battery_pct) |> Enum.min()
      }
    end
  end

  defp avg(readings, key) do
    readings
    |> Enum.map(&Map.get(&1, key, 0))
    |> then(fn vals -> Enum.sum(vals) / length(vals) end)
    |> Float.round(2)
  end

  def alert?(%{temperature: t}) when t > 40.0 or t < -10.0, do: {:alert, :temperature_out_of_range}
  def alert?(%{humidity: h}) when h > 95.0, do: {:alert, :humidity_critical}
  def alert?(%{battery_pct: b}) when b < 10, do: {:alert, :low_battery}
  def alert?(_), do: :ok
end
```
