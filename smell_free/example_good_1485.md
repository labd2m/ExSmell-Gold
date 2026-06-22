```elixir
defmodule Pipeline.DataTransformer do
  @moduledoc """
  Composable data transformation pipeline for ETL processing.
  Each step is a pure function applied sequentially to a data record.
  """

  @type record :: map()
  @type transform_fn :: (record() -> {:ok, record()} | {:error, String.t()})
  @type pipeline :: [transform_fn()]
  @type pipeline_result :: {:ok, record()} | {:error, String.t(), record()}

  @spec build([atom()]) :: pipeline()
  def build(step_names) when is_list(step_names) do
    Enum.map(step_names, &resolve_step/1)
  end

  @spec run(pipeline(), record()) :: pipeline_result()
  def run(pipeline, record) when is_list(pipeline) and is_map(record) do
    Enum.reduce_while(pipeline, {:ok, record}, fn step, {:ok, current} ->
      case step.(current) do
        {:ok, transformed} -> {:cont, {:ok, transformed}}
        {:error, reason} -> {:halt, {:error, reason, current}}
      end
    end)
  end

  @spec run_all(pipeline(), [record()]) :: %{ok: [record()], errors: [{String.t(), record()}]}
  def run_all(pipeline, records) when is_list(pipeline) and is_list(records) do
    Enum.reduce(records, %{ok: [], errors: []}, fn record, acc ->
      case run(pipeline, record) do
        {:ok, result} -> %{acc | ok: [result | acc.ok]}
        {:error, reason, original} -> %{acc | errors: [{reason, original} | acc.errors]}
      end
    end)
  end

  @spec resolve_step(atom()) :: transform_fn()
  defp resolve_step(:normalize_keys), do: &normalize_keys/1
  defp resolve_step(:trim_strings), do: &trim_strings/1
  defp resolve_step(:reject_empty), do: &reject_empty/1
  defp resolve_step(:parse_dates), do: &parse_dates/1
  defp resolve_step(unknown), do: fn _ -> {:error, "Unknown step: #{unknown}"} end

  @spec normalize_keys(record()) :: {:ok, record()}
  defp normalize_keys(record) do
    normalized =
      Map.new(record, fn {k, v} ->
        key = k |> to_string() |> String.downcase() |> String.replace(~r/\s+/, "_")
        {key, v}
      end)

    {:ok, normalized}
  end

  @spec trim_strings(record()) :: {:ok, record()}
  defp trim_strings(record) do
    trimmed =
      Map.new(record, fn
        {k, v} when is_binary(v) -> {k, String.trim(v)}
        {k, v} -> {k, v}
      end)

    {:ok, trimmed}
  end

  @spec reject_empty(record()) :: {:ok, record()} | {:error, String.t()}
  defp reject_empty(record) do
    empty_keys =
      record
      |> Enum.filter(fn {_, v} -> v == nil or v == "" end)
      |> Enum.map(fn {k, _} -> k end)

    if Enum.empty?(empty_keys) do
      {:ok, record}
    else
      {:error, "Empty fields: #{Enum.join(empty_keys, ", ")}"}
    end
  end

  @spec parse_dates(record()) :: {:ok, record()} | {:error, String.t()}
  defp parse_dates(record) do
    date_keys = ["date", "created_at", "updated_at", "issued_on"]

    Enum.reduce_while(date_keys, {:ok, record}, fn key, {:ok, acc} ->
      case Map.get(acc, key) do
        nil -> {:cont, {:ok, acc}}
        value -> parse_and_update(acc, key, value)
      end
    end)
  end

  @spec parse_and_update(record(), String.t(), String.t()) ::
          {:cont, {:ok, record()}} | {:halt, {:error, String.t()}}
  defp parse_and_update(record, key, value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:cont, {:ok, Map.put(record, key, date)}}
      {:error, _} -> {:halt, {:error, "Invalid date format for field '#{key}': #{value}"}}
    end
  end

  defp parse_and_update(record, _key, _value), do: {:cont, {:ok, record}}
end
```
