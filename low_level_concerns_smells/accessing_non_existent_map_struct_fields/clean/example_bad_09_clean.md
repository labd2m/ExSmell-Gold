```elixir
defmodule Auth.SessionManager do
  @moduledoc """
  Creates, validates, and revokes user sessions backed by an in-memory ETS
  table. Intended to be supervised as a named GenServer in production.
  """

  use GenServer

  require Logger

  @table        :sessions
  @default_ttl  3_600

  # ── Client API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec create_session(map(), map()) :: {:ok, String.t()} | {:error, term()}
  def create_session(user, options \\ %{}) do
    GenServer.call(__MODULE__, {:create_session, user, options})
  end

  @spec validate_session(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def validate_session(token, remote_ip) do
    GenServer.call(__MODULE__, {:validate_session, token, remote_ip})
  end

  @spec revoke_session(String.t()) :: :ok
  def revoke_session(token) do
    GenServer.cast(__MODULE__, {:revoke_session, token})
  end

  # ── Server Callbacks ────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create_session, user, options}, _from, state) do
    ttl_seconds = options[:ttl_seconds]
    single_use  = options[:single_use]
    ip_binding  = options[:ip_binding]

    token      = generate_token()
    now        = System.os_time(:second)
    expires_at = now + (ttl_seconds || @default_ttl)

    session = %{
      token: token,
      user_id: user.id,
      user_email: user.email,
      roles: Map.get(user, :roles, []),
      created_at: now,
      expires_at: expires_at,
      single_use: single_use || false,
      ip_binding: ip_binding,
      used: false
    }

    :ets.insert(@table, {token, session})

    Logger.info("Session created",
      user_id: user.id,
      expires_at: expires_at,
      single_use: session.single_use
    )

    {:reply, {:ok, token}, state}
  end

  @impl true
  def handle_call({:validate_session, token, remote_ip}, _from, state) do
    result =
      case :ets.lookup(@table, token) do
        [] ->
          {:error, :session_not_found}

        [{^token, session}] ->
          now = System.os_time(:second)

          cond do
            session.expires_at < now ->
              :ets.delete(@table, token)
              {:error, :session_expired}

            session.ip_binding && session.ip_binding != remote_ip ->
              {:error, :ip_mismatch}

            session.single_use && session.used ->
              {:error, :session_already_used}

            true ->
              updated = %{session | used: true}
              :ets.insert(@table, {token, updated})
              {:ok, session}
          end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:revoke_session, token}, state) do
    :ets.delete(@table, token)
    Logger.info("Session revoked", token: String.slice(token, 0, 8) <> "…")
    {:noreply, state}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec generate_token() :: String.t()
  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
```
