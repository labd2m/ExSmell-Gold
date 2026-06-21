# File: `example_good_550.md`

```elixir
defmodule Auth.TokenRotator do
  @moduledoc """
  Manages automatic refresh-token rotation for third-party OAuth
  integrations, ensuring callers always receive a valid access token
  without manually handling expiry.

  Access tokens are cached in a GenServer keyed by integration ID.
  When a cached token is within the refresh buffer window, the rotator
  exchanges the refresh token for a new access token transparently.
  """

  use GenServer

  require Logger

  @expiry_buffer_seconds 120
  @default_timeout_ms 10_000

  @type integration_id :: String.t()

  @type token_entry :: %{
          access_token: String.t(),
          refresh_token: String.t(),
          expires_at: integer()
        }

  @type provider_opts :: [
          token_url: String.t(),
          client_id: String.t(),
          client_secret: String.t()
        ]

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Stores an initial token pair for an integration.

  Call this after a user completes OAuth authorisation to seed the cache.
  """
  @spec store(integration_id(), String.t(), String.t(), pos_integer()) :: :ok
  def store(integration_id, access_token, refresh_token, expires_in_seconds)
      when is_binary(integration_id) do
    GenServer.cast(__MODULE__, {:store, integration_id, access_token, refresh_token, expires_in_seconds})
  end

  @doc """
  Returns a valid access token for `integration_id`, rotating it if necessary.

  Returns `{:ok, access_token}` or `{:error, :not_found | :rotation_failed}`.
  """
  @spec access_token(integration_id(), provider_opts()) ::
          {:ok, String.t()} | {:error, atom()}
  def access_token(integration_id, provider_opts \\ []) when is_binary(integration_id) do
    GenServer.call(__MODULE__, {:access_token, integration_id, provider_opts}, @default_timeout_ms + 5_000)
  end

  @doc """
  Removes a stored token entry, forcing re-authorisation for the integration.
  """
  @spec revoke(integration_id()) :: :ok
  def revoke(integration_id) when is_binary(integration_id) do
    GenServer.cast(__MODULE__, {:revoke, integration_id})
  end

  @doc """
  Returns the count of integrations with cached tokens.
  """
  @spec cached_count() :: non_neg_integer()
  def cached_count do
    GenServer.call(__MODULE__, :cached_count)
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{tokens: %{}}}

  @impl GenServer
  def handle_cast({:store, id, access, refresh, expires_in}, state) do
    entry = build_entry(access, refresh, expires_in)
    {:noreply, put_in(state, [:tokens, id], entry)}
  end

  @impl GenServer
  def handle_cast({:revoke, id}, state) do
    {:noreply, update_in(state, [:tokens], &Map.delete(&1, id))}
  end

  @impl GenServer
  def handle_call({:access_token, id, provider_opts}, _from, state) do
    case Map.fetch(state.tokens, id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, entry} ->
        if needs_rotation?(entry) do
          rotate_and_reply(id, entry, provider_opts, state)
        else
          {:reply, {:ok, entry.access_token}, state}
        end
    end
  end

  @impl GenServer
  def handle_call(:cached_count, _from, state) do
    {:reply, map_size(state.tokens), state}
  end

  defp needs_rotation?(%{expires_at: exp}) do
    System.system_time(:second) >= exp - @expiry_buffer_seconds
  end

  defp rotate_and_reply(id, entry, provider_opts, state) do
    case perform_rotation(entry.refresh_token, provider_opts) do
      {:ok, new_entry} ->
        Logger.info("Rotated access token for integration #{id}")
        new_state = put_in(state, [:tokens, id], new_entry)
        {:reply, {:ok, new_entry.access_token}, new_state}

      {:error, reason} ->
        Logger.error("Token rotation failed for #{id}: #{inspect(reason)}")
        {:reply, {:error, :rotation_failed}, state}
    end
  end

  defp perform_rotation(refresh_token, provider_opts) do
    token_url = Keyword.fetch!(provider_opts, :token_url)
    client_id = Keyword.fetch!(provider_opts, :client_id)
    client_secret = Keyword.fetch!(provider_opts, :client_secret)

    body =
      URI.encode_query(%{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => client_id,
        "client_secret" => client_secret
      })

    case :httpc.request(:post, {String.to_charlist(token_url), [],
                                ~c"application/x-www-form-urlencoded", body},
                        [{:timeout, @default_timeout_ms}], []) do
      {:ok, {{_, 200, _}, _headers, resp_body}} ->
        parse_token_response(IO.iodata_to_binary(resp_body))

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_token_response(body) do
    case Jason.decode(body) do
      {:ok, %{"access_token" => at, "refresh_token" => rt, "expires_in" => exp}} ->
        {:ok, build_entry(at, rt, exp)}

      {:ok, %{"access_token" => at, "expires_in" => exp} = data} ->
        rt = Map.get(data, "refresh_token", "")
        {:ok, build_entry(at, rt, exp)}

      {:error, _} ->
        {:error, :invalid_response}
    end
  end

  defp build_entry(access_token, refresh_token, expires_in) do
    %{
      access_token: access_token,
      refresh_token: refresh_token,
      expires_at: System.system_time(:second) + expires_in
    }
  end
end
```
