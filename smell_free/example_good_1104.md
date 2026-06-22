```elixir
defmodule Auth.TokenStore do
  @moduledoc """
  Manages short-lived authentication tokens backed by an ETS table.
  The store is registered under a named process and owned by this GenServer,
  so the ETS table is automatically cleaned up on process exit.

  Token expiry is enforced lazily at lookup time and proactively via a
  periodic sweep to keep memory bounded.
  """

  use GenServer

  @table :auth_token_store
  @sweep_interval_ms 60_000

  @type token :: String.t()
  @type claims :: map()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Stores a token with an expiry timestamp (Unix seconds)."
  @spec put(token(), claims(), pos_integer()) :: :ok
  def put(token, claims, expires_at)
      when is_binary(token) and is_map(claims) and is_integer(expires_at) do
    :ets.insert(@table, {token, claims, expires_at})
    :ok
  end

  @doc "Retrieves claims for a token if it exists and has not expired."
  @spec fetch(token()) :: {:ok, claims()} | {:error, :not_found | :expired}
  def fetch(token) when is_binary(token) do
    case :ets.lookup(@table, token) do
      [] -> {:error, :not_found}
      [{^token, claims, expires_at}] -> validate_expiry(claims, expires_at)
    end
  end

  @doc "Removes a token from the store immediately."
  @spec revoke(token()) :: :ok
  def revoke(token) when is_binary(token) do
    :ets.delete(@table, token)
    :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.os_time(:second)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp validate_expiry(claims, expires_at) do
    now = System.os_time(:second)
    if expires_at > now, do: {:ok, claims}, else: {:error, :expired}
  end
end
```
