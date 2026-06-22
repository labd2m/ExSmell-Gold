```elixir
defmodule Analytics.EventProcessor do
  @moduledoc """
  A Flow-based pipeline that ingests raw analytics events from a database
  table, enriches them with session and geo data, and writes aggregated
  summaries to a separate table. Flow's built-in demand-driven back-pressure
  prevents the enrichment stage from being overwhelmed by bursty ingest.
  Window functions accumulate events into 5-minute tumbling windows before
  the aggregation stage reduces them, controlling write amplification.
  """

  alias Analytics.{Event, Repo, SessionStore, Summary}
  alias Geo.IpLookup

  require Logger

  @window_seconds 300
  @max_demand 500
  @min_demand 100

  @doc """
  Processes all unprocessed events from the database in a single bounded run.
  Intended to be called by a scheduled Oban job. Returns a result map
  with counts of events processed and summaries written.
  """
  @spec run(keyword()) :: %{events_processed: non_neg_integer(), summaries_written: non_neg_integer()}
  def run(opts \\ []) do
    window_seconds = Keyword.get(opts, :window_seconds, @window_seconds)

    result =
      event_source()
      |> Flow.from_enumerable(max_demand: @max_demand, min_demand: @min_demand)
      |> Flow.map(&enrich_event/1)
      |> Flow.reject(&is_nil/1)
      |> Flow.partition(key: &session_window_key/1)
      |> Flow.window(Flow.Window.fixed(window_seconds, :second, &event_timestamp/1))
      |> Flow.reduce(fn -> %{} end, &accumulate/2)
      |> Flow.emit(:state)
      |> Flow.map(&build_summary/1)
      |> Flow.map(&persist_summary/1)
      |> Enum.to_list()

    events_processed = length(result)
    summaries_written = Enum.count(result, &match?(:ok, &1))

    Logger.info("Analytics event processing complete",
      events_processed: events_processed,
      summaries_written: summaries_written
    )

    %{events_processed: events_processed, summaries_written: summaries_written}
  end

  # ---------------------------------------------------------------------------
  # Pipeline stages
  # ---------------------------------------------------------------------------

  defp event_source do
    Repo.transaction(fn ->
      Event
      |> where([e], e.processed == false)
      |> order_by([e], asc: e.occurred_at)
      |> Repo.stream(max_rows: 1_000)
    end)
    |> elem(1)
  end

  defp enrich_event(%Event{} = event) do
    geo = IpLookup.country_code(event.client_ip)
    session = SessionStore.get_session_data(event.session_id)

    if session do
      %{
        event_id: event.id,
        event_type: event.event_type,
        user_id: session.user_id,
        session_id: event.session_id,
        country_code: geo,
        platform: session.platform,
        occurred_at: event.occurred_at,
        properties: event.properties
      }
    else
      nil
    end
  end

  defp session_window_key(%{country_code: country, event_type: type}) do
    "#{country}:#{type}"
  end

  defp event_timestamp(%{occurred_at: dt}) do
    DateTime.to_unix(dt)
  end

  defp accumulate(event, acc) do
    key = {event.event_type, event.country_code, event.platform}

    Map.update(acc, key, %{count: 1, user_ids: MapSet.new([event.user_id])}, fn existing ->
      %{
        count: existing.count + 1,
        user_ids: MapSet.put(existing.user_ids, event.user_id)
      }
    end)
  end

  defp build_summary(window_acc) do
    Enum.map(window_acc, fn {{event_type, country, platform}, data} ->
      %{
        event_type: event_type,
        country_code: country,
        platform: platform,
        event_count: data.count,
        unique_users: MapSet.size(data.user_ids),
        window_start: DateTime.utc_now()
      }
    end)
  end

  defp persist_summary(summaries) when is_list(summaries) do
    rows =
      Enum.map(summaries, fn s ->
        Map.merge(s, %{inserted_at: DateTime.utc_now(), updated_at: DateTime.utc_now()})
      end)

    case Repo.insert_all(Summary, rows, on_conflict: :nothing) do
      {_count, _} -> :ok
    end
  end
end
```
