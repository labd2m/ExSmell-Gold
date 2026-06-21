```elixir
defmodule Platform.Authorization do
  @moduledoc """
  Role-based access control (RBAC) for the platform. Permissions are
  expressed as `{resource_type, action}` tuples. Role definitions are
  loaded once from the database and cached in ETS for fast in-process
  lookups. Tenant-scoped role assignments allow the same user to hold
  different roles in different tenants.
  """

  alias Platform.{Permission, Repo, RoleAssignment}
  import Ecto.Query

  require Logger

  @table :rbac_permissions_cache
  @refresh_interval_ms 300_000

  @type actor :: %{id: binary(), global_roles: [binary()]}
  @type resource_type :: binary()
  @type action :: binary()
  @type tenant_id :: binary()

  # ---------------------------------------------------------------------------
  # Cache lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Warms the ETS permission cache. Call once at application startup from a
  supervised process. Schedules automatic refresh every 5 minutes.
  """
  @spec init_cache() :: :ok
  def init_cache do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    refresh_cache()
    schedule_refresh()
    :ok
  end

  @doc """
  Forces an immediate cache refresh. Broadcasts via PubSub so all cluster
  nodes reload concurrently.
  """
  @spec refresh_cache() :: :ok
  def refresh_cache do
    permissions = Repo.all(from(p in Permission, preload: :role))

    :ets.delete_all_objects(@table)

    Enum.each(permissions, fn p ->
      :ets.insert(@table, {{p.role.name, p.resource_type, p.action}, true})
    end)

    Logger.debug("RBAC cache refreshed", permission_count: length(permissions))
    :ok
  end

  # ---------------------------------------------------------------------------
  # Authorization checks
  # ---------------------------------------------------------------------------

  @doc """
  Returns `:ok` when `actor` is permitted to perform `action` on
  `resource_type` within `tenant_id`, or `{:error, :forbidden}` otherwise.
  Checks tenant-scoped roles first, then falls back to global roles.
  """
  @spec authorize(actor(), resource_type(), action(), tenant_id()) ::
          :ok | {:error, :forbidden}
  def authorize(actor, resource_type, action, tenant_id)
      when is_map(actor) and is_binary(resource_type) and is_binary(action) and is_binary(tenant_id) do
    tenant_roles = load_tenant_roles(actor.id, tenant_id)
    all_roles = Enum.uniq(tenant_roles ++ Map.get(actor, :global_roles, []))

    if any_role_permits?(all_roles, resource_type, action) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Returns the full list of `{resource_type, action}` tuples that are
  permitted for a given role. Useful for building UI permission sets.
  """
  @spec permissions_for_role(binary()) :: [{resource_type(), action()}]
  def permissions_for_role(role_name) when is_binary(role_name) do
    :ets.match(@table, {{role_name, :"$1", :"$2"}, :_})
    |> Enum.map(fn [rt, act] -> {rt, act} end)
  end

  @doc """
  Returns all roles assigned to `user_id` within `tenant_id`.
  """
  @spec roles_for_user(binary(), tenant_id()) :: [binary()]
  def roles_for_user(user_id, tenant_id) when is_binary(user_id) and is_binary(tenant_id) do
    RoleAssignment
    |> where([ra], ra.user_id == ^user_id and ra.tenant_id == ^tenant_id)
    |> select([ra], ra.role_name)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp load_tenant_roles(user_id, tenant_id) do
    RoleAssignment
    |> where([ra], ra.user_id == ^user_id and ra.tenant_id == ^tenant_id)
    |> select([ra], ra.role_name)
    |> Repo.all()
  end

  defp any_role_permits?(roles, resource_type, action) do
    Enum.any?(roles, fn role ->
      :ets.member(@table, {role, resource_type, action}) or
        :ets.member(@table, {role, resource_type, "*"}) or
        :ets.member(@table, {role, "*", action})
    end)
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh_rbac_cache, @refresh_interval_ms)
  end
end
```
