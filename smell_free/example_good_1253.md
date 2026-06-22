```elixir
defmodule Iot.Sensors.ReadingPipeline do
  @moduledoc """
  Processes raw sensor reading payloads through a validation, unit conversion,
  and threshold alerting pipeline. Each stage returns an explicit result tuple.
  Readings that pass all stages are forwarded to a configurable sink.
  """

  alias Iot.Sensors.{Reading, UnitConverter, ThresholdConfig}

  @type raw_payload :: %{String.t() => term()}
  @type pipeline_result ::
          {:ok, Reading.t()}
          | {:error, :validation_failed | :conversion_failed | :alert_suppressed, String.t()}

  @doc """
  Processes a single raw sensor payload through the full pipeline.

  ## Options
    - `:sink` - 1-arity function receiving a validated `Reading.t()` (required)
    - `:thresholds` - `ThresholdConfig.t()` for alert evaluation
  """
  @spec process(raw_payload(), keyword()) :: pipeline_result()
  def process(payload, opts) when is_map(payload) and is_list(opts) do
    sink = Keyword.fetch!(opts, :sink)
    thresholds = Keyword.get(opts, :thresholds, ThresholdConfig.defaults())

    with {:ok, reading} <- parse_and_validate(payload),
         {:ok, converted} <- UnitConverter.convert(reading),
         :ok <- evaluate_thresholds(converted, thresholds) do
      sink.(converted)
      {:ok, converted}
    else
      {:error, stage, reason} -> {:error, stage, reason}
    end
  end

  @doc """
  Processes a list of raw payloads concurrently, returning grouped results.
  """
  @spec process_batch([raw_payload()], keyword()) ::
          %{ok: [Reading.t()], errors: [{raw_payload(), term()}]}
  def process_batch(payloads, opts) when is_list(payloads) and is_list(opts) do
    payloads
    |> Task.async_stream(fn p -> {p, process(p, opts)} end,
      ordered: false,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{ok: [], errors: []}, &collect_batch_result/2)
  end

  defp parse_and_validate(payload) do
    with {:ok, sensor_id} <- fetch_string(payload, "sensor_id"),
         {:ok, value} <- fetch_number(payload, "value"),
         {:ok, unit} <- fetch_string(payload, "unit"),
         {:ok, recorded_at} <- fetch_timestamp(payload, "recorded_at") do
      {:ok,
       %Reading{
         sensor_id: sensor_id,
         raw_value: value,
         unit: unit,
         recorded_at: recorded_at
       }}
    else
      {:error, reason} -> {:error, :validation_failed, reason}
    end
  end

  defp evaluate_thresholds(reading, thresholds) do
    case ThresholdConfig.check(thresholds, reading.sensor_id, reading.converted_value) do
      :ok -> :ok
      {:breach, message} -> {:error, :alert_suppressed, message}
    end
  end

  defp fetch_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} when is_binary(v) and v != "" -> {:ok, v}
      {:ok, _} -> {:error, "#{key} must be a non-empty string"}
      :error -> {:error, "#{key} is required"}
    end
  end

  defp fetch_number(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} when is_number(v) -> {:ok, v}
      {:ok, _} -> {:error, "#{key} must be a number"}
      :error -> {:error, "#{key} is required"}
    end
  end

  defp fetch_timestamp(map, key) do
    case Map.fetch(map, key) do
      {:ok, %DateTime{} = dt} -> {:ok, dt}
      {:ok, s} when is_binary(s) -> parse_datetime(s, key)
      {:ok, _} -> {:error, "#{key} must be a DateTime or ISO8601 string"}
      :error -> {:error, "#{key} is required"}
    end
  end

  defp parse_datetime(s, key) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, "#{key} is not a valid ISO8601 timestamp"}
    end
  end

  defp collect_batch_result({:ok, {_payload, {:ok, reading}}}, acc) do
    %{acc | ok: [reading | acc.ok]}
  end

  defp collect_batch_result({:ok, {payload, {:error, _, _} = err}}, acc) do
    %{acc | errors: [{payload, err} | acc.errors]}
  end

  defp collect_batch_result({:exit, _reason}, acc), do: acc
end
```
