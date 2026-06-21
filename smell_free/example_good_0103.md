```elixir
defmodule Analytics.EventIngestionPipeline do
  @moduledoc """
  Accepts a stream of raw event maps, validates and normalises each event,
  enriches it with server-side metadata, and forwards accepted events to a
  configured sink. Rejected events are collected separately for inspection.
  All stages are stateless pure functions; no process boundaries are crossed.
  """

  @type raw_event :: map()
  @type event :: %{
          id: String.t(),
          type: String.t(),
          user_id: String.t(),
          properties: map(),
          received_at: DateTime.t()
        }
  @type rejection :: %{raw: raw_event(), reason: atom()}
  @type sink_fn :: (event() -> :ok)
  @type pipeline_result :: %{accepted: non_neg_integer(), rejected: [rejection()]}

  @required_keys ~w(type user_id properties)

  @doc """
  Runs the ingestion pipeline over `events`. Calls `sink` for every valid
  event. Returns aggregate counts and the list of rejected events.
  """
  @spec run([raw_event()], sink_fn()) :: pipeline_result()
  def run(events, sink) when is_list(events) and is_function(sink, 1) do
    Enum.reduce(events, %{accepted: 0, rejected: []}, fn raw, acc ->
      case process(raw) do
        {:ok, event} ->
          sink.(event)
          Map.update!(acc, :accepted, &(&1 + 1))

        {:error, reason} ->
          rejection = %{raw: raw, reason: reason}
          Map.update!(acc, :rejected, &[rejection | &1])
      end
    end)
    |> Map.update!(:rejected, &Enum.reverse/1)
  end

  @doc "Processes a single raw event through validation, normalisation, and enrichment."
  @spec process(raw_event()) :: {:ok, event()} | {:error, atom()}
  def process(raw) when is_map(raw) do
    with :ok <- validate_required_keys(raw),
         :ok <- validate_event_type(raw["type"]),
         :ok <- validate_user_id(raw["user_id"]) do
      {:ok, enrich(raw)}
    end
  end

  defp validate_required_keys(raw) do
    missing = Enum.find(@required_keys, fn k -> not Map.has_key?(raw, k) end)
    if missing == nil, do: :ok, else: {:error, :missing_required_key}
  end

  defp validate_event_type(type) when is_binary(type) and byte_size(type) > 0, do: :ok
  defp validate_event_type(_), do: {:error, :invalid_event_type}

  defp validate_user_id(user_id) when is_binary(user_id) and byte_size(user_id) > 0, do: :ok
  defp validate_user_id(_), do: {:error, :invalid_user_id}

  defp enrich(raw) do
    %{
      id: generate_id(),
      type: String.downcase(raw["type"]),
      user_id: raw["user_id"],
      properties: Map.get(raw, "properties", %{}),
      received_at: DateTime.utc_now()
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end
end
```
