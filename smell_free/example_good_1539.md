```elixir
defmodule Tenancy.ConfigurationProvider do
  @moduledoc """
  Runtime tenant configuration resolver for multi-tenant deployments.

  Resolves tenant-scoped settings from the database at request time,
  supporting per-tenant feature flags, locale preferences, and integration
  credentials. Configuration is cached per-process to minimize database
  round-trips within a single request lifecycle.
  """

  alias Tenancy.{Tenant, TenantConfig, Repo}

  @type tenant_id :: String.t()
  @type config_key :: atom()
  @type config_value :: String.t() | boolean() | integer() | nil

  @process_key :tenant_config_cache

  @doc """
  Fetches a single configuration value for the given tenant and key.

  Returns `{:ok, value}` if the tenant and key exist, or `{:error, :tenant_not_found}`
  if the tenant does not exist.
  """
  @spec fetch(tenant_id(), config_key()) ::
          {:ok, config_value()} | {:error, :tenant_not_found}
  def fetch(tenant_id, key) when is_binary(tenant_id) and is_atom(key) do
    with {:ok, config_map} <- resolve_tenant_config(tenant_id) do
      {:ok, Map.get(config_map, key)}
    end
  end

  @doc """
  Returns the full configuration map for the given tenant.
  """
  @spec fetch_all(tenant_id()) :: {:ok, map()} | {:error, :tenant_not_found}
  def fetch_all(tenant_id) when is_binary(tenant_id) do
    resolve_tenant_config(tenant_id)
  end

  @doc """
  Clears the per-process configuration cache for the current process.

  Useful when tenant configuration is known to have changed within a long-running
  process or test fixture.
  """
  @spec bust_cache() :: :ok
  def bust_cache do
    Process.delete(@process_key)
    :ok
  end

  defp resolve_tenant_config(tenant_id) do
    cached = Process.get(@process_key)

    case cached do
      %{^tenant_id => config} ->
        {:ok, config}

      _ ->
        case load_from_database(tenant_id) do
          {:ok, config} ->
            store_in_cache(tenant_id, config)
            {:ok, config}

          {:error, :tenant_not_found} = error ->
            error
        end
    end
  end

  defp load_from_database(tenant_id) do
    case Repo.get_by(Tenant, external_id: tenant_id, active: true) do
      nil ->
        {:error, :tenant_not_found}

      tenant ->
        config_entries = Repo.all(TenantConfig.for_tenant_query(tenant.id))
        config_map = build_config_map(config_entries)
        {:ok, config_map}
    end
  end

  defp build_config_map(entries) do
    Map.new(entries, fn entry ->
      {String.to_existing_atom(entry.key), cast_config_value(entry.value, entry.value_type)}
    end)
  end

  defp cast_config_value(raw, :boolean), do: raw in ["true", "1", "yes"]
  defp cast_config_value(raw, :integer), do: String.to_integer(raw)
  defp cast_config_value(raw, :string), do: raw
  defp cast_config_value(raw, _unknown), do: raw

  defp store_in_cache(tenant_id, config) do
    existing = Process.get(@process_key) || %{}
    Process.put(@process_key, Map.put(existing, tenant_id, config))
  end
end
```
