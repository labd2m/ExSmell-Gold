```elixir
defmodule Auth.Token.SessionStore do
  @moduledoc """
  Manages short-lived session tokens stored in ETS.
  Each token maps to a session payload with a configured TTL.
  This store is intended to run under an application supervisor.
  """

  use GenServer

  @table :session_tokens
  @default_ttl_seconds 3_600
  @sweep_interval_ms 60_000

  @type session :: %{user_id: String.t(), metadata: map(), expires_at: integer()}

  @doc """
  Starts the SessionStore linked to the calling process.

  ## Options
    - `:ttl_seconds` - session lifetime in seconds (default: 3600)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores a new session under a freshly generated token.
  Returns `{:ok, token}`.
  """
  @spec create(String.t(), map(), keyword()) :: {:ok, String.t()}
  def create(user_id, metadata, opts \\ [])
      when is_binary(user_id) and is_map(metadata) do
    GenServer.call(__MODULE__, {:create, user_id, metadata, opts})
  end

  @doc """
  Looks up a session by token. Returns `{:ok, session}` or `{:error, :not_found}`.
  """
  @spec fetch(String.t()) :: {:ok, session()} | {:error, :not_found | :expired}
  def fetch(token) when is_binary(token) do
    case :ets.lookup(@table, token) do
      [{^token, session}] -> validate_expiry(session)
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Removes a session token explicitly (e.g., on logout).
  """
  @spec revoke(String.t()) :: :ok
  def revoke(token) when is_binary(token) do
    :ets.delete(@table, token)
    :ok
  end

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    schedule_sweep()
    {:ok, %{ttl_seconds: ttl}}
  end

  @impl GenServer
  def handle_call({:create, user_id, metadata, opts}, _from, state) do
    token = generate_token()
    ttl = Keyword.get(opts, :ttl_seconds, state.ttl_seconds)
    expires_at = System.system_time(:second) + ttl
    session = %{user_id: user_id, metadata: metadata, expires_at: expires_at}
    :ets.insert(@table, {token, session})
    {:reply, {:ok, token}, state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.system_time(:second)
    :ets.select_delete(@table, [{{:_, %{expires_at: :"$1"}}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp validate_expiry(%{expires_at: exp} = session) do
    if System.system_time(:second) < exp do
      {:ok, session}
    else
      {:error, :expired}
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
```
