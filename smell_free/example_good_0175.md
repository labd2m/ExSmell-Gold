```elixir
defmodule Integrations.TokenRefreshWorker do
  @moduledoc """
  A GenServer that manages OAuth2 access tokens for a named external integration.

  The worker proactively refreshes the access token before expiry using a
  configurable buffer window. Callers retrieve the current token via `get_token/1`
  without blocking on network I/O under normal conditions.
  """

  use GenServer

  require Logger

  alias Integrations.OAuth2Client

  @type integration_name :: atom()
  @type token_state :: %{
          access_token: String.t(),
          refresh_token: String.t(),
          expires_at: DateTime.t()
        }

  @refresh_buffer_seconds 120

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the current valid access token for the integration.
  Forces a synchronous refresh if the token has already expired.
  """
  @spec get_token(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def get_token(server) do
    GenServer.call(server, :get_token, 15_000)
  end

  @impl GenServer
  def init(opts) do
    config = %{
      client_id: Keyword.fetch!(opts, :client_id),
      client_secret: Keyword.fetch!(opts, :client_secret),
      token_url: Keyword.fetch!(opts, :token_url),
      refresh_token: Keyword.fetch!(opts, :refresh_token)
    }

    case OAuth2Client.fetch_initial_token(config) do
      {:ok, token_state} ->
        schedule_refresh(token_state)
        {:ok, %{config: config, token: token_state}}

      {:error, reason} ->
        {:stop, {:token_fetch_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:get_token, _from, %{token: token} = state) do
    if token_valid?(token) do
      {:reply, {:ok, token.access_token}, state}
    else
      case refresh(state) do
        {:ok, new_state} -> {:reply, {:ok, new_state.token.access_token}, new_state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    case refresh(state) do
      {:ok, new_state} ->
        Logger.debug("[TokenRefreshWorker] Token refreshed successfully")
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("[TokenRefreshWorker] Token refresh failed", reason: inspect(reason))
        Process.send_after(self(), :refresh, :timer.seconds(30))
        {:noreply, state}
    end
  end

  defp refresh(%{config: config, token: %{refresh_token: rt}} = state) do
    case OAuth2Client.refresh(config, rt) do
      {:ok, token_state} ->
        schedule_refresh(token_state)
        {:ok, %{state | token: token_state}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp token_valid?(%{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :lt
  end

  defp schedule_refresh(%{expires_at: expires_at}) do
    now = DateTime.utc_now()
    seconds_until_expiry = DateTime.diff(expires_at, now, :second)
    refresh_in = max(seconds_until_expiry - @refresh_buffer_seconds, 10)
    Process.send_after(self(), :refresh, :timer.seconds(refresh_in))
  end
end
```
