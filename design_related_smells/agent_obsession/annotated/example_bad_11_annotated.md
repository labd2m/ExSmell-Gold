# Code Smell Example 11

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `SessionStore`, `AuthValidator`, `ActivityLogger`, and `SessionSweeper`
- **Affected functions:** `SessionStore.put/3`, `AuthValidator.validate_token/2`, `ActivityLogger.record_event/3`, `SessionSweeper.purge_expired/1`
- **Short explanation:** The Agent that holds active user sessions is accessed directly from four separate modules across the authentication subsystem. No single module owns the Agent interface; instead, raw `Agent.get/2` and `Agent.update/2` calls are scattered throughout, making it impossible to enforce invariants on session data structure.

```elixir
defmodule SessionStore do
  @moduledoc """
  Initializes the session Agent and provides basic read/write helpers.
  """

  def start_link do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because SessionStore exposes the Agent PID and directly
  # manipulates Agent state, while other modules also reach into the same Agent directly.
  def put(pid, token, session_data) do
    Agent.update(pid, fn sessions ->
      Map.put(sessions, token, Map.put(session_data, :created_at, System.system_time(:second)))
    end)
  end

  def delete(pid, token) do
    Agent.update(pid, fn sessions -> Map.delete(sessions, token) end)
  end

  def all(pid) do
    Agent.get(pid, fn sessions -> sessions end)
  end
  # VALIDATION: SMELL END
end

defmodule AuthValidator do
  @moduledoc """
  Validates bearer tokens against active sessions.
  """

  @token_ttl_seconds 3600

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because AuthValidator directly queries the Agent state
  # to validate a token, rather than going through a dedicated SessionStore function.
  def validate_token(pid, token) do
    now = System.system_time(:second)

    result =
      Agent.get(pid, fn sessions ->
        case Map.fetch(sessions, token) do
          {:ok, %{created_at: created_at} = session} ->
            if now - created_at <= @token_ttl_seconds do
              {:ok, session}
            else
              {:error, :expired}
            end

          :error ->
            {:error, :not_found}
        end
      end)

    result
  end
  # VALIDATION: SMELL END

  def generate_token(user_id) do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
    |> then(&"#{user_id}.#{&1}")
  end
end

defmodule ActivityLogger do
  @moduledoc """
  Appends activity events to the session record for auditing.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because ActivityLogger directly mutates the Agent state
  # to append events, spreading Agent write responsibility to a logging module.
  def record_event(pid, token, event) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    Agent.update(pid, fn sessions ->
      case Map.fetch(sessions, token) do
        {:ok, session} ->
          events = Map.get(session, :events, [])
          updated = Map.put(session, :events, [{event, timestamp} | events])
          Map.put(sessions, token, updated)

        :error ->
          sessions
      end
    end)
  end

  def list_events(pid, token) do
    Agent.get(pid, fn sessions ->
      sessions |> Map.get(token, %{}) |> Map.get(:events, [])
    end)
  end
  # VALIDATION: SMELL END
end

defmodule SessionSweeper do
  @moduledoc """
  Periodically removes expired sessions from the Agent.
  """

  @token_ttl_seconds 3600

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because SessionSweeper independently reaches into the
  # Agent to filter and delete sessions, duplicating logic already partly in AuthValidator.
  def purge_expired(pid) do
    now = System.system_time(:second)

    Agent.update(pid, fn sessions ->
      sessions
      |> Enum.reject(fn {_token, %{created_at: created_at}} ->
        now - created_at > @token_ttl_seconds
      end)
      |> Map.new()
    end)
  end
  # VALIDATION: SMELL END

  def schedule_sweep(pid, interval_ms \\ 60_000) do
    Process.send_after(self(), {:sweep, pid}, interval_ms)
  end

  def handle_info({:sweep, pid}, state) do
    purge_expired(pid)
    schedule_sweep(pid)
    {:noreply, state}
  end
end
```
