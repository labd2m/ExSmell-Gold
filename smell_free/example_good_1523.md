```elixir
defmodule Analytics.SessionTracker do
  @moduledoc """
  Tracks and aggregates per-user session events into structured session
  summaries. Session boundaries are determined by configurable inactivity
  timeouts.

  Each session is stored in ETS for low-overhead writes. Summaries are
  periodically flushed to persistent storage by calling `flush_sessions/0`.
  """

  use GenServer

  alias Analytics.SessionSummary
  alias Analytics.SessionStore

  @inactivity_timeout_ms 30 * 60 * 1_000
  @flush_interval_ms 5 * 60 * 1_000
  @table :session_tracker

  @type user_id :: String.t()
  @type event :: %{type: atom(), occurred_at: DateTime.t(), metadata: map()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Records an event for the given user, creating a new session if
  none exists or the previous one has expired due to inactivity.
  """
  @spec record_event(user_id(), event()) :: :ok
  def record_event(user_id, %{type: _, occurred_at: _, metadata: _} = event)
      when is_binary(user_id) do
    GenServer.cast(__MODULE__, {:record_event, user_id, event})
  end

  @doc """
  Flushes completed sessions to persistent storage and clears
  them from the in-process cache.
  """
  @spec flush_sessions() :: {:ok, non_neg_integer()}
  def flush_sessions do
    GenServer.call(__MODULE__, :flush_sessions)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :private])
    schedule_flush()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast({:record_event, user_id, event}, state) do
    upsert_session(user_id, event)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:flush_sessions, _from, state) do
    count = do_flush()
    {:reply, {:ok, count}, state}
  end

  @impl GenServer
  def handle_info(:scheduled_flush, state) do
    do_flush()
    schedule_flush()
    {:noreply, state}
  end

  @spec upsert_session(user_id(), event()) :: :ok
  defp upsert_session(user_id, event) do
    now = DateTime.utc_now()

    entry =
      case :ets.lookup(@table, user_id) do
        [{^user_id, existing}] ->
          if session_expired?(existing.last_event_at, now) do
            new_session(user_id, event, now)
          else
            append_event(existing, event, now)
          end

        [] ->
          new_session(user_id, event, now)
      end

    :ets.insert(@table, {user_id, entry})
    :ok
  end

  @spec new_session(user_id(), event(), DateTime.t()) :: map()
  defp new_session(user_id, event, now) do
    %{
      user_id: user_id,
      session_id: generate_session_id(),
      started_at: now,
      last_event_at: now,
      events: [event]
    }
  end

  @spec append_event(map(), event(), DateTime.t()) :: map()
  defp append_event(entry, event, now) do
    %{entry | events: [event | entry.events], last_event_at: now}
  end

  @spec session_expired?(DateTime.t(), DateTime.t()) :: boolean()
  defp session_expired?(last_event_at, now) do
    DateTime.diff(now, last_event_at, :millisecond) > @inactivity_timeout_ms
  end

  @spec do_flush() :: non_neg_integer()
  defp do_flush do
    sessions = :ets.tab2list(@table)

    completed =
      Enum.filter(sessions, fn {_user_id, entry} ->
        session_expired?(entry.last_event_at, DateTime.utc_now())
      end)

    Enum.each(completed, fn {user_id, entry} ->
      summary = SessionSummary.from_entry(entry)
      SessionStore.persist(summary)
      :ets.delete(@table, user_id)
    end)

    length(completed)
  end

  @spec schedule_flush() :: reference()
  defp schedule_flush do
    Process.send_after(self(), :scheduled_flush, @flush_interval_ms)
  end

  @spec generate_session_id() :: String.t()
  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
```
