```elixir
defmodule OAuth2.TokenCache do
  @moduledoc false

  @table __MODULE__

  @type entry :: %{access_token: String.t(), expires_at: integer()}

  @spec setup() :: :ok
  def setup do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    :ok
  end

  @spec get(String.t()) :: {:ok, String.t()} | {:error, :not_found | :expired}
  def get(client_id) when is_binary(client_id) do
    now = System.system_time(:second)

    case :ets.lookup(@table, client_id) do
      [{^client_id, %{access_token: token, expires_at: exp}}] when exp > now ->
        {:ok, token}

      [{^client_id, _expired}] ->
        {:error, :expired}

      [] ->
        {:error, :not_found}
    end
  end

  @spec put(String.t(), String.t(), pos_integer()) :: :ok
  def put(client_id, access_token, expires_in)
      when is_binary(client_id) and is_binary(access_token) and
             is_integer(expires_in) and expires_in > 0 do
    entry = %{
      access_token: access_token,
      expires_at: System.system_time(:second) + expires_in - 30
    }

    :ets.insert(@table, {client_id, entry})
    :ok
  end

  @spec invalidate(String.t()) :: :ok
  def invalidate(client_id) when is_binary(client_id) do
    :ets.delete(@table, client_id)
    :ok
  end
end

defmodule OAuth2.TokenManager do
  @moduledoc """
  Manages client-credential OAuth2 access tokens with automatic refresh.

  Tokens are cached in ETS so reads never serialize through this process.
  When a token is absent or expired, a single refresh request is serialized
  through the GenServer; the cache is re-checked inside the handler so that
  concurrent callers waiting for the same client do not trigger redundant
  network requests.
  """

  use GenServer

  alias OAuth2.TokenCache

  @type credentials :: %{
          required(:client_id) => String.t(),
          required(:client_secret) => String.t(),
          required(:token_url) => String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec fetch(credentials()) :: {:ok, String.t()} | {:error, term()}
  def fetch(%{client_id: client_id} = credentials) do
    case TokenCache.get(client_id) do
      {:ok, token} -> {:ok, token}
      {:error, _miss} -> GenServer.call(__MODULE__, {:refresh, credentials})
    end
  end

  @spec invalidate(String.t()) :: :ok
  def invalidate(client_id) when is_binary(client_id) do
    GenServer.cast(__MODULE__, {:invalidate, client_id})
  end

  @impl GenServer
  def init(_opts) do
    TokenCache.setup()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:refresh, %{client_id: client_id} = credentials}, _from, state) do
    reply =
      case TokenCache.get(client_id) do
        {:ok, token} -> {:ok, token}
        {:error, _} -> request_token(credentials)
      end

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_cast({:invalidate, client_id}, state) do
    TokenCache.invalidate(client_id)
    {:noreply, state}
  end

  defp request_token(%{client_id: cid, client_secret: secret, token_url: url}) do
    body =
      URI.encode_query(%{
        grant_type: "client_credentials",
        client_id: cid,
        client_secret: secret
      })

    headers = [{~c"content-type", ~c"application/x-www-form-urlencoded"}]

    case :httpc.request(:post, {to_charlist(url), headers, ~c"application/x-www-form-urlencoded", body}, [], []) do
      {:ok, {{_, 200, _}, _resp_headers, resp_body}} ->
        with {:ok, %{"access_token" => token, "expires_in" => exp}} <-
               Jason.decode(to_string(resp_body)) do
          TokenCache.put(cid, token, exp)
          {:ok, token}
        end

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end
end
```
