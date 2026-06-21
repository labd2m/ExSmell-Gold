# File: `example_good_238.md`

```elixir
defmodule Auth.SessionManager do
  @moduledoc """
  GenServer managing authenticated user sessions with sliding expiry.

  Each session is renewed on every successful access, extending its
  lifetime by the configured idle timeout. Absolute maximum session
  duration is enforced independently to bound the lifetime regardless
  of activity. A periodic sweep evicts fully expired sessions.
  """

  use GenServer

  @default_idle_timeout_s 1_800
  @default_max_lifetime_s 86_400
  @sweep_interval_ms 60_000

  @type session_id :: String.t()
  @type user_id :: String.t()

  @type session :: %{
          user_id: user_id(),
          data: map(),
          created_at: integer(),
          last_accessed_at: integer(),
          idle_timeout_s: pos_integer(),
          max_lifetime_s: pos_integer()
        }

  @type opts :: [
          idle_timeout_s: pos_integer(),
          max_lifetime_s: pos_integer()
        ]

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new session for `user_id` with optional initial data.
  Returns `{:ok, session_id}`.
  """
  @spec create(user_id(), map(), opts()) :: {:ok, session_id()}
  def create(user_id, data \\ %{}, opts \\ []) when is_binary(user_id) and is_map(data) do
    GenServer.call(__MODULE__, {:create, user_id, data, opts})
  end

  @doc """
  Fetches a session by ID, sliding its expiry on success.

  Returns `{:ok, session}`, `{:error, :not_found}`, or `{:error, :expired}`.
  """
  @spec fetch(session_id()) :: {:ok, session()} | {:error, :not_found | :expired}
  def fetch(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:fetch, session_id})
  end

  @doc """
  Updates the arbitrary data map stored in an existing session.
  """
  @spec update_data(session_id(), map()) :: :ok | {:error, :not_found | :expired}
  def update_data(session_id, data) when is_binary(session_id) and is_map(data) do
    GenServer.call(__MODULE__, {:update_data, session_id, data})
  end

  @doc """
  Invalidates a session immediately.
  """
  @spec invalidate(session_id()) :: :ok
  def invalidate(session_id) when is_binary(session_id) do
    GenServer.cast(__MODULE__, {:invalidate, session_id})
  end

  @doc """
  Returns the count of currently active sessions.
  """
  @spec active_count() :: non_neg_integer()
  def active_count do
    GenServer.call(__MODULE__, :active_count)
  end

  @impl GenServer
  def init(opts) do
    idle_timeout_s = Keyword.get(opts, :idle_timeout_s, @default_idle_timeout_s)
    max_lifetime_s = Keyword.get(opts, :max_lifetime_s, @default_max_lifetime_s)
    schedule_sweep()
    {:ok, %{sessions: %{}, idle_timeout_s: idle_timeout_s, max_lifetime_s: max_lifetime_s}}
  end

  @impl GenServer
  def handle_call({:create, user_id, data, opts}, _from, state) do
    session_id = generate_session_id()
    now = now_s()

    session = %{
      user_id: user_id,
      data: data,
      created_at: now,
      last_accessed_at: now,
      idle_timeout_s: Keyword.get(opts, :idle_timeout_s, state.idle_timeout_s),
      max_lifetime_s: Keyword.get(opts, :max_lifetime_s, state.max_lifetime_s)
    }

    {:reply, {:ok, session_id}, put_in(state, [:sessions, session_id], session)}
  end

  @impl GenServer
  def handle_call({:fetch, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, session} -> handle_fetch_result(state, session_id, session)
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_call({:update_data, session_id, data}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, session} ->
        if expired?(session) do
          {:reply, {:error, :expired}, state}
        else
          updated = %{session | data: data, last_accessed_at: now_s()}
          {:reply, :ok, put_in(state, [:sessions, session_id], updated)}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_call(:active_count, _from, state) do
    {:reply, map_size(state.sessions), state}
  end

  @impl GenServer
  def handle_cast({:invalidate, session_id}, state) do
    {:noreply, update_in(state, [:sessions], &Map.delete(&1, session_id))}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    live = Map.reject(state.sessions, fn {_id, session} -> expired?(session) end)
    schedule_sweep()
    {:noreply, %{state | sessions: live}}
  end

  defp handle_fetch_result(state, session_id, session) do
    if expired?(session) do
      new_state = update_in(state, [:sessions], &Map.delete(&1, session_id))
      {:reply, {:error, :expired}, new_state}
    else
      refreshed = %{session | last_accessed_at: now_s()}
      {:reply, {:ok, refreshed}, put_in(state, [:sessions, session_id], refreshed)}
    end
  end

  defp expired?(%{created_at: created, last_accessed_at: accessed,
                  idle_timeout_s: idle, max_lifetime_s: max_life}) do
    now = now_s()
    now - accessed > idle or now - created > max_life
  end

  defp now_s, do: System.system_time(:second)

  defp generate_session_id do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
```
