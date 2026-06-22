```elixir
defmodule Auth.Sessions.TokenStore do
  @moduledoc """
  Supervised ETS-backed session token store with TTL-based expiry.

  Manages short-lived access token issuance, lookup, and revocation
  within a GenServer that owns the underlying ETS table.
  """

  use GenServer, restart: :permanent

  @table_name :auth_session_tokens
  @cleanup_interval_ms 60_000

  @type token :: String.t()
  @type session_id :: String.t()

  @type token_record :: %{
          session_id: session_id(),
          user_id: String.t(),
          expires_at: DateTime.t()
        }

  @doc """
  Starts the token store under a supervisor.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Issues a new token for the given user session.

  Returns `{:ok, token}` with a signed token string.
  """
  @spec issue(String.t(), String.t(), pos_integer()) :: {:ok, token()}
  def issue(session_id, user_id, ttl_seconds) when is_binary(session_id) and is_binary(user_id) and is_integer(ttl_seconds) do
    token = generate_token()
    expires_at = DateTime.add(DateTime.utc_now(), ttl_seconds, :second)
    record = %{session_id: session_id, user_id: user_id, expires_at: expires_at}
    :ets.insert(@table_name, {token, record})
    {:ok, token}
  end

  @doc """
  Looks up a token and returns its session data if valid and unexpired.
  """
  @spec lookup(token()) :: {:ok, token_record()} | {:error, :invalid_token} | {:error, :expired}
  def lookup(token) when is_binary(token) do
    case :ets.lookup(@table_name, token) do
      [{^token, record}] -> validate_expiry(record)
      [] -> {:error, :invalid_token}
    end
  end

  @doc """
  Explicitly revokes a token, removing it from the store.
  """
  @spec revoke(token()) :: :ok
  def revoke(token) when is_binary(token) do
    :ets.delete(@table_name, token)
    :ok
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:cleanup_expired, state) do
    remove_expired_tokens()
    schedule_cleanup()
    {:noreply, state}
  end

  defp validate_expiry(%{expires_at: expires_at} = record) do
    if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
      {:ok, record}
    else
      {:error, :expired}
    end
  end

  defp remove_expired_tokens do
    now = DateTime.utc_now()

    :ets.foldl(
      fn {token, %{expires_at: expires_at}}, acc ->
        if DateTime.compare(now, expires_at) != :lt do
          :ets.delete(@table_name, token)
        end

        acc
      end,
      :ok,
      @table_name
    )
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_expired, @cleanup_interval_ms)
  end
end
```
