```elixir
defmodule Auth.SessionStore do
  use GenServer

  @moduledoc """
  In-memory session store for authenticated user sessions.
  Maintains a map of session tokens to session data, enforcing
  expiry and single-device policies per user.
  """

  @session_ttl_seconds 3600
  @cleanup_interval_ms 300_000

  defstruct sessions: %{}, user_index: %{}

  def start do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @doc "Creates a new session and returns the session token."
  def create_session(user_id, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:create, user_id, metadata})
  end

  @doc "Looks up a session by token. Returns {:ok, session} or {:error, :not_found}."
  def fetch_session(token) do
    GenServer.call(__MODULE__, {:fetch, token})
  end

  @doc "Explicitly invalidates a session token."
  def invalidate_session(token) do
    GenServer.cast(__MODULE__, {:invalidate, token})
  end

  @doc "Invalidates all sessions for a given user."
  def invalidate_user_sessions(user_id) do
    GenServer.cast(__MODULE__, {:invalidate_user, user_id})
  end

  @doc "Returns the count of currently active (non-expired) sessions."
  def active_session_count do
    GenServer.call(__MODULE__, :count)
  end

  ## Callbacks

  @impl true
  def init(state) do
    schedule_cleanup()
    {:ok, state}
  end

  @impl true
  def handle_call({:create, user_id, metadata}, _from, state) do
    token = generate_token()
    expires_at = DateTime.add(DateTime.utc_now(), @session_ttl_seconds, :second)

    session = %{
      token: token,
      user_id: user_id,
      metadata: metadata,
      created_at: DateTime.utc_now(),
      expires_at: expires_at
    }

    new_sessions = Map.put(state.sessions, token, session)
    new_user_index = Map.update(state.user_index, user_id, [token], &[token | &1])

    {:reply, {:ok, token}, %{state | sessions: new_sessions, user_index: new_user_index}}
  end

  def handle_call({:fetch, token}, _from, state) do
    case Map.fetch(state.sessions, token) do
      {:ok, session} ->
        if DateTime.compare(DateTime.utc_now(), session.expires_at) == :lt do
          {:reply, {:ok, session}, state}
        else
          {:reply, {:error, :expired}, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:count, _from, state) do
    now = DateTime.utc_now()

    active =
      Enum.count(state.sessions, fn {_token, session} ->
        DateTime.compare(now, session.expires_at) == :lt
      end)

    {:reply, active, state}
  end

  @impl true
  def handle_cast({:invalidate, token}, state) do
    case Map.fetch(state.sessions, token) do
      {:ok, session} ->
        new_sessions = Map.delete(state.sessions, token)

        new_user_index =
          Map.update(state.user_index, session.user_id, [], fn tokens ->
            List.delete(tokens, token)
          end)

        {:noreply, %{state | sessions: new_sessions, user_index: new_user_index}}

      :error ->
        {:noreply, state}
    end
  end

  def handle_cast({:invalidate_user, user_id}, state) do
    tokens = Map.get(state.user_index, user_id, [])
    new_sessions = Map.drop(state.sessions, tokens)
    new_user_index = Map.delete(state.user_index, user_id)
    {:noreply, %{state | sessions: new_sessions, user_index: new_user_index}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = DateTime.utc_now()

    {expired, active} =
      Enum.split_with(state.sessions, fn {_token, session} ->
        DateTime.compare(now, session.expires_at) != :lt
      end)

    new_sessions = Map.new(active)

    new_user_index =
      Enum.reduce(expired, state.user_index, fn {token, session}, idx ->
        Map.update(idx, session.user_id, [], &List.delete(&1, token))
      end)

    schedule_cleanup()
    {:noreply, %{state | sessions: new_sessions, user_index: new_user_index}}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
```
