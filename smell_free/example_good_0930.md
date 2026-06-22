```elixir
defmodule Platform.EphemeralTokenStore do
  @moduledoc """
  A GenServer-backed store for short-lived, single-use tokens such as
  email verification links, magic login links, and invite codes.

  Tokens are stored in ETS with an expiry timestamp. Each token is consumed
  on first successful redemption, preventing replay. Expired tokens are
  evicted lazily on read and eagerly via a periodic sweep.
  """

  use GenServer

  @type token :: String.t()
  @type purpose :: atom()
  @type payload :: map()
  @type create_result :: {:ok, token()}
  @type redeem_result :: {:ok, payload()} | {:error, :not_found | :expired | :wrong_purpose}

  @default_ttl_seconds 900
  @sweep_interval_ms :timer.minutes(5)
  @token_bytes 32

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Creates a token for `purpose` carrying `payload`.
  Returns `{:ok, token}` where token is a URL-safe string.
  """
  @spec create(purpose(), payload(), pos_integer()) :: create_result()
  def create(purpose, payload \\ %{}, ttl_seconds \\ @default_ttl_seconds)
      when is_atom(purpose) and is_map(payload) and is_integer(ttl_seconds) do
    token = generate_token()
    GenServer.call(__MODULE__, {:create, token, purpose, payload, ttl_seconds})
  end

  @doc """
  Redeems a token for `purpose`. The token is consumed on success and
  cannot be used again. Returns `{:ok, payload}` or an error.
  """
  @spec redeem(token(), purpose()) :: redeem_result()
  def redeem(token, purpose) when is_binary(token) and is_atom(purpose) do
    GenServer.call(__MODULE__, {:redeem, token, purpose})
  end

  @doc """
  Looks up a token without consuming it. Useful for validation previews.
  Returns `{:ok, payload}` or an error.
  """
  @spec peek(token(), purpose()) :: redeem_result()
  def peek(token, purpose) when is_binary(token) and is_atom(purpose) do
    GenServer.call(__MODULE__, {:peek, token, purpose})
  end

  @doc "Explicitly invalidates a token before it expires."
  @spec revoke(token()) :: :ok
  def revoke(token) when is_binary(token) do
    GenServer.cast(__MODULE__, {:revoke, token})
  end

  @impl GenServer
  def init(_opts) do
    table = :ets.new(:ephemeral_tokens, [:set, :private])
    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:create, token, purpose, payload, ttl_seconds}, _from, %{table: table} = state) do
    entry = %{purpose: purpose, payload: payload, expires_at: future_unix(ttl_seconds)}
    :ets.insert(table, {token, entry})
    {:reply, {:ok, token}, state}
  end

  @impl GenServer
  def handle_call({:redeem, token, purpose}, _from, %{table: table} = state) do
    result = case :ets.lookup(table, token) do
      [{^token, %{purpose: ^purpose, expires_at: exp, payload: payload}}] ->
        if exp > now_unix() do
          :ets.delete(table, token)
          {:ok, payload}
        else
          :ets.delete(table, token)
          {:error, :expired}
        end

      [{^token, %{purpose: _other}}] ->
        {:error, :wrong_purpose}

      [] ->
        {:error, :not_found}
    end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:peek, token, purpose}, _from, %{table: table} = state) do
    result = case :ets.lookup(table, token) do
      [{^token, %{purpose: ^purpose, expires_at: exp, payload: payload}}] ->
        if exp > now_unix(), do: {:ok, payload}, else: {:error, :expired}
      [{^token, %{purpose: _other}}] ->
        {:error, :wrong_purpose}
      [] ->
        {:error, :not_found}
    end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_cast({:revoke, token}, %{table: table} = state) do
    :ets.delete(table, token)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:sweep, %{table: table} = state) do
    current = now_unix()
    :ets.select_delete(table, [{{:_, %{expires_at: :"$1"}}, [{:<, :"$1", current}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp generate_token do
    :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
  end

  defp future_unix(ttl_seconds), do: System.os_time(:second) + ttl_seconds
  defp now_unix, do: System.os_time(:second)
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
```
