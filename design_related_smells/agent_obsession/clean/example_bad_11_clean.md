```elixir
defmodule SessionStore do
  @moduledoc """
  Initializes the session Agent and provides basic read/write helpers.
  """

  def start_link do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

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
end

defmodule AuthValidator do
  @moduledoc """
  Validates bearer tokens against active sessions.
  """

  @token_ttl_seconds 3600

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
end

defmodule SessionSweeper do
  @moduledoc """
  Periodically removes expired sessions from the Agent.
  """

  @token_ttl_seconds 3600

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
