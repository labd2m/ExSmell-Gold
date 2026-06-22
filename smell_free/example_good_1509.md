```elixir
defmodule Auth.TokenServer do
  @moduledoc """
  GenServer that manages short-lived API token leases for external
  service integrations.

  Tokens are cached in-process and automatically refreshed before
  expiry using a scheduled `Process.send_after/3` message. Callers
  request tokens via `fetch_token/1` and receive valid credentials
  without knowledge of the refresh cycle.
  """

  use GenServer

  require Logger

  @refresh_buffer_seconds 60

  @type provider :: :analytics | :storage | :notifications
  @type token_entry :: %{token: String.t(), expires_at: DateTime.t()}
  @type state :: %{provider() => token_entry()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Returns a valid token for the given provider, fetching or refreshing
  as needed. Blocks until the token is available.
  """
  @spec fetch_token(provider()) :: {:ok, String.t()} | {:error, :provider_unavailable}
  def fetch_token(provider) when provider in [:analytics, :storage, :notifications] do
    GenServer.call(__MODULE__, {:fetch_token, provider})
  end

  @impl GenServer
  def init(state) do
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:fetch_token, provider}, _from, state) do
    case Map.get(state, provider) do
      %{token: token, expires_at: exp} when not is_nil(token) ->
        if token_valid?(exp) do
          {:reply, {:ok, token}, state}
        else
          refresh_and_reply(provider, state)
        end

      nil ->
        refresh_and_reply(provider, state)
    end
  end

  @impl GenServer
  def handle_info({:refresh_token, provider}, state) do
    Logger.debug("Proactive token refresh triggered for provider: #{provider}")

    case acquire_token(provider) do
      {:ok, entry} ->
        schedule_refresh(provider, entry.expires_at)
        {:noreply, Map.put(state, provider, entry)}

      {:error, reason} ->
        Logger.warning("Token refresh failed for #{provider}: #{inspect(reason)}")
        {:noreply, Map.delete(state, provider)}
    end
  end

  @spec refresh_and_reply(provider(), state()) ::
          {:reply, {:ok, String.t()} | {:error, :provider_unavailable}, state()}
  defp refresh_and_reply(provider, state) do
    case acquire_token(provider) do
      {:ok, entry} ->
        schedule_refresh(provider, entry.expires_at)
        {:reply, {:ok, entry.token}, Map.put(state, provider, entry)}

      {:error, _reason} ->
        {:reply, {:error, :provider_unavailable}, Map.delete(state, provider)}
    end
  end

  @spec acquire_token(provider()) :: {:ok, token_entry()} | {:error, term()}
  defp acquire_token(provider) do
    Auth.TokenAdapter.request(provider)
  end

  @spec token_valid?(DateTime.t()) :: boolean()
  defp token_valid?(expires_at) do
    DateTime.diff(expires_at, DateTime.utc_now(), :second) > @refresh_buffer_seconds
  end

  @spec schedule_refresh(provider(), DateTime.t()) :: reference()
  defp schedule_refresh(provider, expires_at) do
    ms_until_refresh =
      max(0, (DateTime.diff(expires_at, DateTime.utc_now(), :second) - @refresh_buffer_seconds) * 1000)

    Process.send_after(self(), {:refresh_token, provider}, ms_until_refresh)
  end
end
```
