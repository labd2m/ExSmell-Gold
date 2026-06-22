**File:** `example_good_1066.md`

```elixir
defmodule ETL.Pipeline do
  @moduledoc """
  Composable data transformation pipeline for processing raw webhook payloads
  into normalized domain records. Each stage returns a tagged tuple and the
  pipeline short-circuits on the first failure.
  """

  alias ETL.{RawEvent, NormalizedEvent, EnrichmentService, ValidationRules}

  @type pipeline_result :: {:ok, NormalizedEvent.t()} | {:error, pipeline_error()}
  @type pipeline_error :: {:validation_failed, [String.t()]} | {:enrichment_failed, term()} | {:parse_failed, term()}

  @spec process(map()) :: pipeline_result()
  def process(raw_payload) when is_map(raw_payload) do
    with {:ok, raw_event} <- parse_payload(raw_payload),
         :ok <- validate(raw_event),
         {:ok, enriched} <- enrich(raw_event),
         {:ok, normalized} <- normalize(enriched) do
      {:ok, normalized}
    end
  end

  @spec process_batch([map()]) :: %{ok: [NormalizedEvent.t()], error: [pipeline_error()]}
  def process_batch(payloads) when is_list(payloads) do
    payloads
    |> Enum.map(&process/1)
    |> Enum.reduce(%{ok: [], error: []}, &partition_result/2)
    |> Map.update!(:ok, &Enum.reverse/1)
    |> Map.update!(:error, &Enum.reverse/1)
  end

  defp parse_payload(%{"event_type" => type, "timestamp" => ts, "data" => data} = payload)
       when is_binary(type) and is_map(data) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} ->
        event = %RawEvent{
          event_type: type,
          occurred_at: dt,
          source_id: payload["source_id"],
          data: data
        }

        {:ok, event}

      {:error, reason} ->
        {:error, {:parse_failed, {:invalid_timestamp, reason}}}
    end
  end

  defp parse_payload(payload) do
    missing = required_fields() -- Map.keys(payload)
    {:error, {:parse_failed, {:missing_fields, missing}}}
  end

  defp validate(%RawEvent{} = event) do
    errors = ValidationRules.run(event)

    if errors == [] do
      :ok
    else
      {:error, {:validation_failed, errors}}
    end
  end

  defp enrich(%RawEvent{source_id: nil} = event) do
    {:ok, event}
  end

  defp enrich(%RawEvent{source_id: source_id} = event) do
    case EnrichmentService.fetch_source_metadata(source_id) do
      {:ok, metadata} -> {:ok, %{event | data: Map.merge(event.data, metadata)}}
      {:error, reason} -> {:error, {:enrichment_failed, reason}}
    end
  end

  defp normalize(%RawEvent{event_type: type, occurred_at: ts, data: data}) do
    normalized = %NormalizedEvent{
      id: generate_id(type, ts),
      type: type,
      occurred_at: ts,
      payload: flatten_data(data),
      processed_at: DateTime.utc_now()
    }

    {:ok, normalized}
  end

  defp flatten_data(data) when is_map(data) do
    data
    |> Enum.flat_map(&expand_entry/1)
    |> Map.new()
  end

  defp expand_entry({key, value}) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {"#{key}.#{k}", v} end)
  end

  defp expand_entry(entry), do: [entry]

  defp partition_result({:ok, value}, acc), do: Map.update!(acc, :ok, &[value | &1])
  defp partition_result({:error, reason}, acc), do: Map.update!(acc, :error, &[reason | &1])

  defp required_fields, do: ["event_type", "timestamp", "data"]

  defp generate_id(type, %DateTime{} = ts) do
    hash = :crypto.hash(:sha256, "#{type}:#{DateTime.to_unix(ts, :microsecond)}")
    Base.encode16(hash, case: :lower)
  end
end
```
