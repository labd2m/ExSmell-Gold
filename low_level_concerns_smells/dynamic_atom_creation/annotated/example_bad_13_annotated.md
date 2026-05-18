# Annotated Example — Dynamic Atom Creation

| Field | Value |
|---|---|
| **Smell name** | Dynamic atom creation |
| **Expected smell location** | `TenantConfigLoader.decode_settings/1`, line where `String.to_atom/1` converts setting keys |
| **Affected function(s)** | `TenantConfigLoader.decode_settings/1` |
| **Short explanation** | Tenant settings are stored as a JSON object in the database, decoded at runtime, and their keys are converted to atoms. Because each tenant can in principle store arbitrary setting keys—especially in a configurable SaaS product—every unique key string becomes a permanent atom across all tenants and all deployments. |

```elixir
defmodule MyApp.Tenancy.TenantConfigLoader do
  @moduledoc """
  Loads, caches, and provides access to per-tenant configuration settings.
  Settings are stored as a JSONB column in the `tenants` table and decoded
  into a structured map on first access per node restart.
  """

  use GenServer

  require Logger

  alias MyApp.Repo

  @cache_table :tenant_config_cache
  @refresh_interval_ms 60_000

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the settings map for a tenant, loading from DB if not cached.
  """
  @spec get_settings(String.t()) :: map()
  def get_settings(tenant_id) when is_binary(tenant_id) do
    case :ets.lookup(@cache_table, tenant_id) do
      [{^tenant_id, settings}] -> settings
      [] -> GenServer.call(__MODULE__, {:load, tenant_id})
    end
  end

  @doc """
  Returns a single setting value for a tenant.
  """
  @spec get(String.t(), atom(), any()) :: any()
  def get(tenant_id, key, default \\ nil) when is_atom(key) do
    tenant_id
    |> get_settings()
    |> Map.get(key, default)
  end

  @doc """
  Invalidates the cached configuration for a tenant, forcing a reload.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(tenant_id) do
    :ets.delete(@cache_table, tenant_id)
    :ok
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    :ets.new(@cache_table, [:named_table, :public, read_concurrency: true])
    schedule_refresh()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:load, tenant_id}, _from, state) do
    settings = load_from_db(tenant_id)
    :ets.insert(@cache_table, {tenant_id, settings})
    {:reply, settings, state}
  end

  @impl GenServer
  def handle_info(:refresh_all, state) do
    Logger.debug("Refreshing all tenant configs")
    tenant_ids = :ets.select(@cache_table, [{{:"$1", :_}, [], [:"$1"]}])
    Enum.each(tenant_ids, &reload_tenant/1)
    schedule_refresh()
    {:noreply, state}
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh_all, @refresh_interval_ms)

  defp reload_tenant(tenant_id) do
    settings = load_from_db(tenant_id)
    :ets.insert(@cache_table, {tenant_id, settings})
  end

  defp load_from_db(tenant_id) do
    case Repo.get_tenant_settings(tenant_id) do
      nil ->
        Logger.warning("Tenant not found in DB", tenant_id: tenant_id)
        %{}

      %{"settings" => settings} ->
        decode_settings(settings)

      _ ->
        %{}
    end
  end

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is applied to every key
  # in the JSON settings object retrieved from the database. Tenants in a SaaS
  # platform often have diverse, product-specific configuration keys; new keys are
  # added via migrations or admin tools at any time. Each unique key across all
  # tenants creates a new permanent atom. With many tenants, each with distinct
  # setting schemas, this can silently exhaust the 1_048_576 atom limit.
  defp decode_settings(settings) when is_map(settings) do
    Map.new(settings, fn {key, value} ->
      {String.to_atom(key), decode_value(value)}
    end)
  end
  # VALIDATION: SMELL END

  defp decode_settings(_), do: %{}

  defp decode_value(v) when is_map(v), do: decode_settings(v)
  defp decode_value(v) when is_list(v), do: Enum.map(v, &decode_value/1)
  defp decode_value(v), do: v
end
```
