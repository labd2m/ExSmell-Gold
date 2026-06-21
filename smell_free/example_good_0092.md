# File: `example_good_92.md`

```elixir
defmodule OAuth.TokenExchange do
  @moduledoc """
  Handles OAuth 2.0 token acquisition and refresh for outbound service
  integrations using the client credentials and authorization code flows.

  Tokens are cached in a supervised GenServer keyed by client ID so that
  multiple callers share a single valid token without redundant network
  requests. The cache refreshes proactively before expiry.
  """

  use GenServer

  require Logger

  @expiry_buffer_seconds 60
  @default_timeout_ms 10_000

  @type client_id :: String.t()
  @type token_entry :: %{
          access_token: String.t(),
          expires_at: integer()
        }

  @type token_opts :: [
          client_id: client_id(),
          client_secret: String.t(),
          token_url: String.t(),
          scope: String.t() | nil,
          timeout_ms: pos_integer()
        ]

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Returns a valid access token for the given client credentials.

  Fetches a new token from the authorization server if none is cached
  or the cached token is near expiry. Returns `{:ok, token}` or
  `{:error, reason}`.
  """
  @spec fetch_token(token_opts()) :: {:ok, String.t()} | {:error, term()}
  def fetch_token(opts) when is_list(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    GenServer.call(__MODULE__, {:fetch_token, client_id, opts}, 15_000)
  end

  @doc """
  Forces a cache invalidation for the given client ID, causing the next
  `fetch_token/1` call to acquire a fresh token from the server.
  """
  @spec invalidate(client_id()) :: :ok
  def invalidate(client_id) when is_binary(client_id) do
    GenServer.cast(__MODULE__, {:invalidate, client_id})
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{cache: %{}}}
  end

  @impl GenServer
  def handle_call({:fetch_token, client_id, opts}, _from, state) do
    case Map.get(state.cache, client_id) do
      %{access_token: token, expires_at: exp} when exp > buffered_now() ->
        {:reply, {:ok, token}, state}

      _expired_or_missing ->
        acquire_and_cache(state, client_id, opts)
    end
  end

  @impl GenServer
  def handle_cast({:invalidate, client_id}, state) do
    {:noreply, update_in(state, [:cache], &Map.delete(&1, client_id))}
  end

  defp acquire_and_cache(state, client_id, opts) do
    case request_token(opts) do
      {:ok, entry} ->
        new_state = put_in(state, [:cache, client_id], entry)
        {:reply, {:ok, entry.access_token}, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  defp request_token(opts) do
    url = Keyword.fetch!(opts, :token_url)
    client_id = Keyword.fetch!(opts, :client_id)
    client_secret = Keyword.fetch!(opts, :client_secret)
    scope = Keyword.get(opts, :scope)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    body = build_request_body(client_id, client_secret, scope)

    case :httpc.request(:post, {String.to_charlist(url), [], ~c"application/x-www-form-urlencoded", body}, [{:timeout, timeout}], []) do
      {:ok, {{_, 200, _}, _headers, resp_body}} ->
        parse_token_response(IO.iodata_to_binary(resp_body))

      {:ok, {{_, status, _}, _headers, resp_body}} ->
        Logger.warning("Token request failed with status #{status}: #{resp_body}")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp build_request_body(client_id, client_secret, nil) do
    "grant_type=client_credentials&client_id=#{URI.encode_www_form(client_id)}&client_secret=#{URI.encode_www_form(client_secret)}"
    |> String.to_charlist()
  end

  defp build_request_body(client_id, client_secret, scope) do
    "grant_type=client_credentials&client_id=#{URI.encode_www_form(client_id)}&client_secret=#{URI.encode_www_form(client_secret)}&scope=#{URI.encode_www_form(scope)}"
    |> String.to_charlist()
  end

  defp parse_token_response(body) do
    case Jason.decode(body) do
      {:ok, %{"access_token" => token, "expires_in" => expires_in}} ->
        entry = %{
          access_token: token,
          expires_at: System.system_time(:second) + expires_in
        }
        {:ok, entry}

      {:ok, %{"error" => error}} ->
        {:error, {:server_error, error}}

      {:error, _reason} ->
        {:error, :invalid_response}
    end
  end

  defp buffered_now do
    System.system_time(:second) + @expiry_buffer_seconds
  end
end
```
