```elixir
defmodule Config.SecretProvider do
  @moduledoc """
  Resolves application secrets from a prioritised chain of providers:
  first from environment variables, then from HashiCorp Vault when a
  Vault address is configured, and finally from compiled defaults for
  non-sensitive values. Secrets are cached in ETS after the first fetch
  so repeated reads within a process lifetime are fast. The cache is
  automatically invalidated when Vault lease renewal fails, forcing a
  fresh fetch on the next access.
  """

  use GenServer

  require Logger

  @table :secret_cache
  @lease_renewal_ms 30 * 60 * 1_000

  @type secret_key :: binary()
  @type secret_value :: binary()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the value for `secret_key`, consulting the provider chain.
  Returns `{:ok, value}` or `{:error, :not_found}`.
  """
  @spec fetch(secret_key()) :: {:ok, secret_value()} | {:error, :not_found}
  def fetch(key) when is_binary(key) do
    case lookup_cache(key) do
      {:ok, value} -> {:ok, value}
      :miss -> GenServer.call(__MODULE__, {:fetch, key})
    end
  end

  @doc """
  Returns the value or raises `ArgumentError` when the key cannot be found.
  Prefer `fetch/1` for graceful handling; use this only for required secrets
  that must be present at startup.
  """
  @spec fetch!(secret_key()) :: secret_value()
  def fetch!(key) when is_binary(key) do
    case fetch(key) do
      {:ok, value} -> value
      {:error, :not_found} -> raise ArgumentError, "Required secret #{inspect(key)} not found"
    end
  end

  @doc """
  Invalidates the cached value for `key`. The next `fetch/1` call will
  re-query the provider chain.
  """
  @spec invalidate(secret_key()) :: :ok
  def invalidate(key) when is_binary(key) do
    :ets.delete(@table, key)
    :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    vault_addr = Keyword.get(opts, :vault_address) || System.get_env("VAULT_ADDR")
    vault_token = System.get_env("VAULT_TOKEN")
    schedule_lease_renewal()

    state = %{
      vault_address: vault_addr,
      vault_token: vault_token,
      vault_available: not is_nil(vault_addr) and not is_nil(vault_token)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:fetch, key}, _from, state) do
    case resolve(key, state) do
      {:ok, value} ->
        :ets.insert(@table, {key, value})
        {:reply, {:ok, value}, state}

      :not_found ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_info(:renew_leases, %{vault_available: true} = state) do
    case renew_vault_leases(state) do
      :ok ->
        schedule_lease_renewal()
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Vault lease renewal failed, invalidating cache", reason: inspect(reason))
        :ets.delete_all_objects(@table)
        schedule_lease_renewal()
        {:noreply, state}
    end
  end

  def handle_info(:renew_leases, state) do
    schedule_lease_renewal()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp lookup_cache(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  end

  defp resolve(key, state) do
    with :not_found <- from_env(key),
         :not_found <- from_vault(key, state) do
      :not_found
    end
  end

  defp from_env(key) do
    env_key = key |> String.upcase() |> String.replace(".", "_").replace("-", "_")

    case System.get_env(env_key) do
      nil -> :not_found
      value -> {:ok, value}
    end
  end

  defp from_vault(_key, %{vault_available: false}), do: :not_found

  defp from_vault(key, %{vault_address: addr, vault_token: token}) do
    path = vault_path(key)
    url = "#{addr}/v1/#{path}"
    headers = [{"X-Vault-Token", token}, {"Content-Type", "application/json"}]

    case Req.get(url, headers: headers, receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200, body: %{"data" => %{"value" => value}}}} ->
        {:ok, value}

      {:ok, %Req.Response{status: 404}} ->
        :not_found

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Vault returned unexpected status", key: key, status: status)
        :not_found

      {:error, reason} ->
        Logger.warning("Vault request failed", key: key, reason: inspect(reason))
        :not_found
    end
  end

  defp vault_path(key) do
    app = Application.get_env(:my_app, :vault_path_prefix, "secret/myapp")
    "#{app}/#{key}"
  end

  defp renew_vault_leases(%{vault_address: addr, vault_token: token}) do
    url = "#{addr}/v1/auth/token/renew-self"
    headers = [{"X-Vault-Token", token}]

    case Req.post(url, headers: headers) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :renewal_failed}
    end
  end

  defp schedule_lease_renewal do
    Process.send_after(self(), :renew_leases, @lease_renewal_ms)
  end
end
```
