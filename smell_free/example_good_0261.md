```elixir
defmodule Auth.TokenCache do
  @moduledoc """
  A supervised GenServer that caches OAuth 2.0 access tokens keyed by
  client credentials. Tokens are proactively evicted when their TTL expires,
  ensuring callers always receive a valid, unexpired token without
  making unnecessary token-exchange requests to the authorization server.
  """

  use GenServer

  require Logger

  @type client_id :: binary()
  @type token_entry :: %{access_token: binary(), expires_at: integer()}

  @clock_skew_seconds 30
  @cleanup_interval_ms 60_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the token cache and links it to the calling supervisor.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns a valid access token for the given `client_id`.
  Fetches and caches a fresh token if none exists or the cached one has expired.
  Returns `{:ok, token}` or `{:error, reason}`.
  """
  @spec fetch(client_id()) :: {:ok, binary()} | {:error, term()}
  def fetch(client_id) when is_binary(client_id) do
    GenServer.call(__MODULE__, {:fetch, client_id})
  end

  @doc """
  Explicitly invalidates the cached token for `client_id`, forcing a fresh
  exchange on the next `fetch/1` call.
  """
  @spec invalidate(client_id()) :: :ok
  def invalidate(client_id) when is_binary(client_id) do
    GenServer.cast(__MODULE__, {:invalidate, client_id})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:fetch, client_id}, _from, cache) do
    case Map.get(cache, client_id) do
      entry when not is_nil(entry) and not is_expired(entry) ->
        {:reply, {:ok, entry.access_token}, cache}

      _ ->
        exchange_and_cache(client_id, cache)
    end
  end

  @impl GenServer
  def handle_cast({:invalidate, client_id}, cache) do
    {:noreply, Map.delete(cache, client_id)}
  end

  @impl GenServer
  def handle_info(:cleanup, cache) do
    pruned = evict_expired(cache)
    schedule_cleanup()
    {:noreply, pruned}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp exchange_and_cache(client_id, cache) do
    case Auth.OAuthClient.exchange_client_credentials(client_id) do
      {:ok, %{access_token: token, expires_in: ttl}} ->
        entry = build_entry(token, ttl)
        {:reply, {:ok, token}, Map.put(cache, client_id, entry)}

      {:error, reason} ->
        Logger.error("Token exchange failed for client #{client_id}: #{inspect(reason)}")
        {:reply, {:error, reason}, cache}
    end
  end

  defp build_entry(token, expires_in) do
    %{
      access_token: token,
      expires_at: unix_now() + expires_in - @clock_skew_seconds
    }
  end

  defp is_expired(%{expires_at: expires_at}), do: unix_now() >= expires_at

  defp evict_expired(cache) do
    now = unix_now()
    Map.reject(cache, fn {_k, entry} -> entry.expires_at <= now end)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp unix_now, do: System.system_time(:second)
end
```
