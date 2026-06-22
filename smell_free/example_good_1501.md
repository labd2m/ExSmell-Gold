```elixir
defmodule Analytics.SessionTracker do
  @moduledoc """
  Tracks user session activity and computes session-level engagement metrics.
  Sessions are keyed by a unique session ID and persist in a supervised GenServer.
  """

  use GenServer

  @type event_type :: :page_view | :click | :form_submit | :purchase
  @type event :: %{type: event_type(), path: String.t(), occurred_at: DateTime.t()}
  @type session :: %{
    id: String.t(),
    user_id: String.t() | nil,
    started_at: DateTime.t(),
    events: [event()],
    last_active_at: DateTime.t()
  }
  @type state :: %{sessions: %{String.t() => session()}}

  @session_timeout_ms 30 * 60 * 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{sessions: %{}}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec start_session(String.t(), String.t() | nil) :: {:ok, session()}
  def start_session(session_id, user_id \\ nil)
      when is_binary(session_id) do
    GenServer.call(__MODULE__, {:start_session, session_id, user_id})
  end

  @spec record_event(String.t(), event_type(), String.t()) ::
          {:ok, session()} | {:error, :session_not_found}
  def record_event(session_id, type, path)
      when is_binary(session_id) and is_binary(path) do
    GenServer.call(__MODULE__, {:record_event, session_id, type, path})
  end

  @spec get_session(String.t()) :: {:ok, session()} | {:error, :not_found}
  def get_session(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:get_session, session_id})
  end

  @spec session_summary(session()) :: map()
  def session_summary(%{events: events, started_at: started_at, last_active_at: last_active} = session) do
    duration_seconds = DateTime.diff(last_active, started_at)
    event_counts = Enum.frequencies_by(events, & &1.type)

    %{
      session_id: session.id,
      user_id: session.user_id,
      duration_seconds: duration_seconds,
      total_events: length(events),
      event_breakdown: event_counts,
      started_at: started_at
    }
  end

  @impl GenServer
  def init(state) do
    schedule_cleanup()
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:start_session, id, user_id}, _from, state) do
    now = DateTime.utc_now()
    session = %{id: id, user_id: user_id, started_at: now, events: [], last_active_at: now}
    {:reply, {:ok, session}, put_in(state, [:sessions, id], session)}
  end

  def handle_call({:record_event, session_id, type, path}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :session_not_found}, state}

      session ->
        event = %{type: type, path: path, occurred_at: DateTime.utc_now()}
        updated = %{session | events: [event | session.events], last_active_at: event.occurred_at}
        {:reply, {:ok, updated}, put_in(state, [:sessions, session_id], updated)}
    end
  end

  def handle_call({:get_session, session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil -> {:reply, {:error, :not_found}, state}
      session -> {:reply, {:ok, session}, state}
    end
  end

  @impl GenServer
  def handle_info(:cleanup_stale_sessions, state) do
    cutoff = DateTime.add(DateTime.utc_now(), -@session_timeout_ms, :millisecond)
    active = Map.reject(state.sessions, fn {_, s} -> DateTime.before?(s.last_active_at, cutoff) end)
    schedule_cleanup()
    {:noreply, %{state | sessions: active}}
  end

  @spec schedule_cleanup() :: reference()
  defp schedule_cleanup, do: Process.send_after(self(), :cleanup_stale_sessions, @session_timeout_ms)
end
```
