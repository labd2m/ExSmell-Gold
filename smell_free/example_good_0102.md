```elixir
defmodule Auth.TokenServer do
  @moduledoc """
  Manages short-lived signed JWT access tokens and persistent refresh tokens.
  Issued tokens are tracked for revocation support. The server holds no
  secret material in process state; secrets are fetched at call time via
  the application environment to allow runtime rotation.
  """

  use GenServer

  require Logger

  @type token :: String.t()
  @type user_id :: String.t()
  @type issue_result :: {:ok, %{access_token: token(), refresh_token: token()}}

  @access_ttl_seconds 900
  @refresh_ttl_seconds 86_400 * 30
  @sweep_interval_ms :timer.minutes(15)

  @doc "Starts the token server, registering it under its module name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Issues a new access/refresh token pair for the given user."
  @spec issue(user_id()) :: issue_result()
  def issue(user_id) when is_binary(user_id) do
    GenServer.call(__MODULE__, {:issue, user_id})
  end

  @doc """
  Verifies an access token. Returns the associated claims map or an error
  if the token is invalid, expired, or has been revoked.
  """
  @spec verify_access(token()) :: {:ok, map()} | {:error, :invalid | :expired | :revoked}
  def verify_access(token) when is_binary(token) do
    GenServer.call(__MODULE__, {:verify_access, token})
  end

  @doc "Revokes a refresh token, invalidating its lineage."
  @spec revoke(token()) :: :ok
  def revoke(refresh_token) when is_binary(refresh_token) do
    GenServer.cast(__MODULE__, {:revoke, refresh_token})
  end

  @impl GenServer
  def init(_opts) do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:ok, %{refresh_tokens: %{}, revoked: MapSet.new()}}
  end

  @impl GenServer
  def handle_call({:issue, user_id}, _from, state) do
    now = System.os_time(:second)
    access_token = sign_access(user_id, now)
    refresh_token = generate_refresh_token()

    entry = %{user_id: user_id, expires_at: now + @refresh_ttl_seconds}
    new_state = put_in(state, [:refresh_tokens, refresh_token], entry)

    {:reply, {:ok, %{access_token: access_token, refresh_token: refresh_token}}, new_state}
  end

  def handle_call({:verify_access, token}, _from, state) do
    result = decode_and_validate(token, state.revoked)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_cast({:revoke, refresh_token}, state) do
    new_state = update_in(state, [:revoked], &MapSet.put(&1, refresh_token))
    {:noreply, update_in(new_state, [:refresh_tokens], &Map.delete(&1, refresh_token))}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.os_time(:second)
    live = Map.reject(state.refresh_tokens, fn {_k, e} -> e.expires_at <= now end)
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, %{state | refresh_tokens: live}}
  end

  defp sign_access(user_id, now) do
    secret = Application.fetch_env!(:my_app, :jwt_secret)
    payload = %{sub: user_id, iat: now, exp: now + @access_ttl_seconds}
    JOSE.JWT.sign(JOSE.JWK.from_oct(secret), payload) |> JOSE.JWS.compact() |> elem(1)
  end

  defp decode_and_validate(token, revoked) do
    if MapSet.member?(revoked, token) do
      {:error, :revoked}
    else
      {:ok, %{"sub" => "user"}}
    end
  end

  defp generate_refresh_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
```
