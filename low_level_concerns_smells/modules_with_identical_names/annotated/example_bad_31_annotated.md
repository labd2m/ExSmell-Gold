# Annotated Example 31 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with identical names
- **Expected smell location:** Both `defmodule Analytics.EventTracker` declarations
- **Affected functions:** `Analytics.EventTracker.track/3`, `Analytics.EventTracker.identify/2`, `Analytics.EventTracker.page_view/2`, `Analytics.EventTracker.flush/0`, `Analytics.EventTracker.batch_track/1`
- **Short explanation:** Two different source files both declare `defmodule Analytics.EventTracker`. BEAM can load only one definition at a time; the second file's definition silently replaces the first, permanently losing any function defined only in the discarded version and producing silent data gaps in the analytics pipeline.

---

```elixir
# ── file: lib/analytics/event_tracker.ex ────────────────────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This is a smell because `Analytics.EventTracker` is declared here
# and again in a second block below. BEAM will keep only one definition;
# functions from the overwritten version will raise `UndefinedFunctionError`.

defmodule Analytics.EventTracker do
  @moduledoc """
  Core analytics event tracking: ingestion, buffering, and flushing.
  Defined in `lib/analytics/event_tracker.ex`.
  """

  alias Analytics.{Buffer, EventSchema, Enricher, SinkDispatcher}

  @buffer_name :analytics_event_buffer
  @max_buffer_size 500
  @flush_interval_ms 5_000

  @type event_name :: String.t()
  @type user_id :: String.t()
  @type properties :: map()

  @doc """
  Track a named event for a specific user with optional properties.
  Events are buffered and flushed to the sink on a schedule.
  """
  @spec track(user_id(), event_name(), properties()) :: :ok | {:error, String.t()}
  def track(user_id, event_name, properties \\ %{}) do
    with {:ok, validated} <- EventSchema.validate(event_name, properties),
         enriched <- Enricher.enrich(user_id, validated) do
      event = %{
        id: generate_id(),
        user_id: user_id,
        name: event_name,
        properties: enriched,
        occurred_at: DateTime.utc_now(),
        server_time: System.system_time(:millisecond)
      }

      Buffer.push(@buffer_name, event)

      if Buffer.size(@buffer_name) >= @max_buffer_size do
        flush()
      end

      :ok
    end
  end

  @doc "Associate a user ID with a set of identifying traits."
  @spec identify(user_id(), map()) :: :ok
  def identify(user_id, traits) do
    event = %{
      type: :identify,
      user_id: user_id,
      traits: traits,
      occurred_at: DateTime.utc_now()
    }

    Buffer.push(@buffer_name, event)
    :ok
  end

  @doc "Record a page view event for a user."
  @spec page_view(user_id(), map()) :: :ok
  def page_view(user_id, page_attrs) do
    track(user_id, "page_viewed", Map.merge(%{source: "web"}, page_attrs))
  end

  @doc "Flush all buffered events to the configured analytics sink."
  @spec flush() :: {:ok, non_neg_integer()} | {:error, String.t()}
  def flush do
    events = Buffer.drain(@buffer_name)

    case SinkDispatcher.dispatch_all(events) do
      :ok -> {:ok, length(events)}
      {:error, reason} -> {:error, "Flush failed: #{inspect(reason)}"}
    end
  end

  @doc "Track a list of events in a single buffered operation."
  @spec batch_track([map()]) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def batch_track(events) when is_list(events) do
    results =
      Enum.map(events, fn %{user_id: uid, name: name} = e ->
        track(uid, name, Map.get(e, :properties, %{}))
      end)

    failed = Enum.count(results, &match?({:error, _}, &1))

    if failed == 0 do
      {:ok, length(events)}
    else
      {:error, "#{failed} of #{length(events)} events failed to track"}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end

# VALIDATION: SMELL END

# ── file: lib/analytics/event_tracker_replay.ex  (replay tooling added later;
#    developer accidentally reused the module name) ──────────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This second `defmodule Analytics.EventTracker` replaces the first
# in BEAM's module registry. `track/3`, `identify/2`, `page_view/2`, `flush/0`,
# and `batch_track/1` all vanish, creating silent gaps in analytics data.

defmodule Analytics.EventTracker do
  @moduledoc """
  Event replay and backfill utilities for the analytics pipeline.
  Was intended to be `Analytics.EventTracker.Replay` but was accidentally
  given the same module name as the core tracker.
  """

  alias Analytics.{EventStore, SinkDispatcher}

  @doc "Replay all events for a user between two datetimes."
  @spec replay_for_user(String.t(), DateTime.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def replay_for_user(user_id, from, to) do
    events = EventStore.query(user_id: user_id, from: from, to: to)

    case SinkDispatcher.dispatch_all(events) do
      :ok -> {:ok, length(events)}
      {:error, reason} -> {:error, "Replay failed: #{inspect(reason)}"}
    end
  end

  @doc "Backfill events from a raw list (e.g., imported CSV data)."
  @spec backfill([map()]) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def backfill(raw_events) when is_list(raw_events) do
    normalized =
      Enum.map(raw_events, fn e ->
        Map.merge(e, %{replayed: true, replay_time: DateTime.utc_now()})
      end)

    case SinkDispatcher.dispatch_all(normalized) do
      :ok ->
        Enum.each(normalized, &EventStore.mark_replayed(&1.id))
        {:ok, length(normalized)}

      {:error, reason} ->
        {:error, "Backfill failed: #{inspect(reason)}"}
    end
  end

  @doc "List all events that failed to sink and are pending replay."
  @spec pending_replays() :: [map()]
  def pending_replays do
    EventStore.query(status: :failed) |> Enum.sort_by(& &1.occurred_at)
  end

  @doc "Retry all pending failed events."
  @spec retry_failed() :: {:ok, non_neg_integer()} | {:error, String.t()}
  def retry_failed do
    events = pending_replays()
    backfill(events)
  end
end

# VALIDATION: SMELL END
```
