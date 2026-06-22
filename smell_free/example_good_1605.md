```elixir
defmodule Platform.TenantConfig do
  @moduledoc """
  Resolves per-tenant runtime configuration from a layered source hierarchy.

  Configuration is resolved by merging: default values < global overrides < tenant-specific
  overrides. All lookups accept an explicit tenant struct rather than relying on
  process dictionary or global application environment.
  """

  alias Platform.TenantConfig.{Defaults, TenantStore, Schema}

  @type tenant :: %{id: String.t(), plan: atom()}
  @type config_key :: atom()
  @type resolved :: %{atom() => term()}

  @doc """
  Returns the fully resolved configuration map for a tenant.

  Keys not defined by the tenant inherit their global or default values.
  """
  @spec resolve(tenant()) :: {:ok, resolved()} | {:error, String.t()}
  def resolve(%{id: tenant_id, plan: plan}) when is_binary(tenant_id) and is_atom(plan) do
    with {:ok, defaults} <- Defaults.for_plan(plan),
         {:ok, overrides} <- TenantStore.fetch(tenant_id) do
      merged = deep_merge(defaults, overrides)
      {:ok, merged}
    end
  end

  def resolve(_), do: {:error, "invalid tenant"}

  @doc """
  Returns the resolved value for a single configuration key.
  """
  @spec get(tenant(), config_key()) :: {:ok, term()} | {:error, :not_found | String.t()}
  def get(tenant, key) when is_atom(key) do
    with {:ok, config} <- resolve(tenant) do
      case Map.fetch(config, key) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, :not_found}
      end
    end
  end

  @doc """
  Updates a single tenant override key, validated against the schema.
  """
  @spec put(tenant(), config_key(), term()) :: :ok | {:error, String.t()}
  def put(%{id: tenant_id} = tenant, key, value)
      when is_binary(tenant_id) and is_atom(key) do
    with :ok <- Schema.validate_key_value(key, value),
         {:ok, existing} <- TenantStore.fetch(tenant_id),
         updated = Map.put(existing, key, value),
         :ok <- TenantStore.save(tenant_id, updated) do
      :ok
    end
  end

  def put(_, _, _), do: {:error, "invalid tenant or key"}

  @doc """
  Removes a tenant-specific override, reverting the key to its default value.
  """
  @spec reset(tenant(), config_key()) :: :ok | {:error, String.t()}
  def reset(%{id: tenant_id}, key) when is_binary(tenant_id) and is_atom(key) do
    with {:ok, existing} <- TenantStore.fetch(tenant_id),
         updated = Map.delete(existing, key),
         :ok <- TenantStore.save(tenant_id, updated) do
      :ok
    end
  end

  def reset(_, _), do: {:error, "invalid tenant or key"}

  # --- private helpers ---

  defp deep_merge(base, overrides) when is_map(base) and is_map(overrides) do
    Map.merge(base, overrides, fn _key, base_val, override_val ->
      if is_map(base_val) and is_map(override_val) do
        deep_merge(base_val, override_val)
      else
        override_val
      end
    end)
  end
end

defmodule Platform.TenantConfig.Schema do
  @moduledoc false

  @valid_keys %{
    max_seats: :integer,
    sso_enabled: :boolean,
    custom_domain: :string,
    storage_limit_gb: :integer,
    api_rate_limit: :integer
  }

  @spec validate_key_value(atom(), term()) :: :ok | {:error, String.t()}
  def validate_key_value(key, value) do
    case Map.fetch(@valid_keys, key) do
      {:ok, :integer} when is_integer(value) -> :ok
      {:ok, :boolean} when is_boolean(value) -> :ok
      {:ok, :string} when is_binary(value) -> :ok
      {:ok, expected} -> {:error, "#{key} expects #{expected}, got #{inspect(value)}"}
      :error -> {:error, "unknown configuration key: #{key}"}
    end
  end
end
```
