```elixir
defmodule MyApp.Infra.SecretManager do
  @moduledoc """
  Fetches and caches application secrets from AWS Secrets Manager.
  Secrets are loaded lazily on first access, cached in ETS with a
  configurable TTL, and refreshed transparently on expiry. The module
  exposes a uniform `get/1` API so that callers never deal with AWS SDK
  specifics directly, making it straightforward to swap providers in test
  or local environments via configuration.

  Start this module under the application supervisor:

      children = [MyApp.Infra.SecretManager]
  """

  use GenServer

  require Logger

  @table __MODULE__
  @default_ttl_ms 15 * 60 * 1_000

  @type secret_name :: String.t()
  @type secret_value :: String.t() | map()

  @doc "Starts the secret manager."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the value of `secret_name`. Fetches from the provider and
  caches the result on the first call; subsequent calls within the TTL
  window read directly from ETS without a GenServer round-trip.
  """
  @spec get(secret_name()) :: {:ok, secret_value()} | {:error, term()}
  def get(secret_name) when is_binary(secret_name) do
    case ets_lookup(secret_name) do
      {:ok, value} -> {:ok, value}
      :miss -> GenServer.call(__MODULE__, {:fetch, secret_name})
    end
  end

  @doc "Evicts the cached value for `secret_name`, forcing a reload on next access."
  @spec invalidate(secret_name()) :: :ok
  def invalidate(secret_name) when is_binary(secret_name) do
    :ets.delete(@table, secret_name)
    :ok
  end

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms)}}
  end

  @impl GenServer
  def handle_call({:fetch, secret_name}, _from, state) do
    case ets_lookup(secret_name) do
      {:ok, value} ->
        {:reply, {:ok, value}, state}

      :miss ->
        result = fetch_from_provider(secret_name)

        if match?({:ok, _}, result) do
          {:ok, value} = result
          cache_value(secret_name, value, state.ttl_ms)
        end

        {:reply, result, state}
    end
  end

  @spec ets_lookup(secret_name()) :: {:ok, secret_value()} | :miss
  defp ets_lookup(secret_name) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, secret_name) do
      [{^secret_name, value, expires_at}] when expires_at > now -> {:ok, value}
      _ -> :miss
    end
  end

  @spec cache_value(secret_name(), secret_value(), pos_integer()) :: :ok
  defp cache_value(secret_name, value, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {secret_name, value, expires_at})
    :ok
  end

  @spec fetch_from_provider(secret_name()) :: {:ok, secret_value()} | {:error, term()}
  defp fetch_from_provider(secret_name) do
    Logger.debug("secret_manager_fetching", secret: secret_name)
    provider().fetch(secret_name)
  end

  @spec provider() :: module()
  defp provider do
    Application.get_env(:my_app, :secret_manager_provider, MyApp.Infra.AWSSecretsProvider)
  end
end
```
