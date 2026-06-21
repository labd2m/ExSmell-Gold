# File: `example_good_05.md`

```elixir
defmodule Analytics.EventIngester do
  @moduledoc """
  Handles ingestion of raw analytics events through a structured pipeline
  of validation, deduplication, transformation, and persistence.

  Each stage returns a tagged tuple so the pipeline can short-circuit
  cleanly on any failure without relying on exception propagation.
  """

  alias Analytics.{Event, EventStore, DeduplicationCache}

  @type raw_event :: %{
          required(:event_type) => String.t(),
          required(:user_id) => String.t(),
          required(:properties) => map(),
          required(:occurred_at) => DateTime.t()
        }

  @type ingest_result ::
          {:ok, Event.t()}
          | {:error, :duplicate}
          | {:error, :invalid_event}
          | {:error, :storage_failed}

  @type batch_summary :: %{
          succeeded: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc """
  Ingests a single raw event through the full processing pipeline.

  Returns `{:ok, event}` on success or a tagged error describing the
  stage at which processing stopped.
  """
  @spec ingest(raw_event()) :: ingest_result()
  def ingest(raw_event) when is_map(raw_event) do
    with {:ok, validated} <- validate(raw_event),
         {:ok, event} <- transform(validated),
         :ok <- check_duplicate(event),
         {:ok, stored} <- persist(event) do
      {:ok, stored}
    end
  end

  @doc """
  Ingests a list of raw events, processing each independently.

  Individual failures do not abort the batch. Returns one result
  tuple per input event in the same order.
  """
  @spec ingest_batch([raw_event()]) :: [ingest_result()]
  def ingest_batch(raw_events) when is_list(raw_events) do
    Enum.map(raw_events, &ingest/1)
  end

  @doc """
  Summarizes the outcome of a batch ingestion result list.

  Returns a map with `:succeeded` and `:failed` counts.
  """
  @spec summarize([ingest_result()]) :: batch_summary()
  def summarize(results) when is_list(results) do
    Enum.reduce(results, %{succeeded: 0, failed: 0}, &tally/2)
  end

  defp validate(%{event_type: type, user_id: uid, properties: props, occurred_at: ts})
       when is_binary(type) and byte_size(type) > 0 and
              is_binary(uid) and byte_size(uid) > 0 and
              is_map(props) do
    if is_struct(ts, DateTime) do
      {:ok, %{event_type: type, user_id: uid, properties: props, occurred_at: ts}}
    else
      {:error, :invalid_event}
    end
  end

  defp validate(_raw), do: {:error, :invalid_event}

  defp transform(validated) do
    event = %Event{
      id: derive_event_id(validated),
      type: validated.event_type,
      user_id: validated.user_id,
      properties: normalize_keys(validated.properties),
      occurred_at: validated.occurred_at,
      ingested_at: DateTime.utc_now()
    }

    {:ok, event}
  end

  defp check_duplicate(%Event{id: id}) do
    case DeduplicationCache.seen?(id) do
      true -> {:error, :duplicate}
      false -> :ok
    end
  end

  defp persist(%Event{} = event) do
    case EventStore.insert(event) do
      {:ok, stored} ->
        DeduplicationCache.mark_seen(stored.id)
        {:ok, stored}

      {:error, _reason} ->
        {:error, :storage_failed}
    end
  end

  defp derive_event_id(%{event_type: type, user_id: uid, occurred_at: ts}) do
    payload = "#{type}:#{uid}:#{DateTime.to_unix(ts)}"
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  defp normalize_keys(props) do
    Map.new(props, fn {k, v} -> {to_string(k), v} end)
  end

  defp tally({:ok, _}, acc), do: Map.update!(acc, :succeeded, &(&1 + 1))
  defp tally({:error, _}, acc), do: Map.update!(acc, :failed, &(&1 + 1))
end
```
