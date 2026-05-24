```elixir
defmodule MyApp.AccessControl.PolicyEnforcer do
  @moduledoc """
  Evaluates access control decisions for a given actor, action, and resource.
  Applies role-based grants, explicit denies, clearance levels, and IP restrictions.
  """

  alias MyApp.AccessControl.{UserRole, ResourcePolicy}
  alias MyApp.Identity.ActorContext

  @audit_actions [:delete, :export, :admin_override]

  def authorize(actor_id, action, resource_id) do
    context = ActorContext.load(actor_id)
    role    = UserRole.for_actor(actor_id)
    policy  = ResourcePolicy.for_resource(resource_id)

    granted_actions  = role.granted_actions
    inherited_roles  = role.inherited_roles
    deny_list        = role.deny_list

    required_clearance = policy.required_clearance
    owner_only         = policy.owner_only
    ip_restrictions    = policy.ip_restrictions

    inherited_grants =
      Enum.flat_map(inherited_roles, fn role_id ->
        case UserRole.for_role_id(role_id) do
          nil  -> []
          r    -> r.granted_actions
        end
      end)

    all_grants = Enum.uniq(granted_actions ++ inherited_grants)

    cond do
      action in deny_list ->
        {:deny, :explicitly_denied}

      owner_only and context.user_id != resource_owner(resource_id) ->
        {:deny, :owner_only_resource}

      required_clearance != nil and context.clearance_level < required_clearance ->
        {:deny, :insufficient_clearance}

      ip_restrictions != [] and context.ip_address not in ip_restrictions ->
        {:deny, :ip_not_allowed}

      action not in all_grants ->
        {:deny, :action_not_granted}

      true ->
        if action in @audit_actions, do: emit_audit_event(actor_id, action, resource_id)
        {:allow, :granted}
    end
  end

  def bulk_check(actor_id, checks) when is_list(checks) do
    Enum.map(checks, fn {action, resource_id} ->
      result = authorize(actor_id, action, resource_id)
      {action, resource_id, result}
    end)
  end

  def permitted_actions(actor_id, resource_id) do
    role   = UserRole.for_actor(actor_id)
    policy = ResourcePolicy.for_resource(resource_id)

    all_actions = [:read, :write, :delete, :export, :share, :admin_override]

    Enum.filter(all_actions, fn action ->
      match?({:allow, _}, authorize(actor_id, action, resource_id))
    end)
  end


  defp resource_owner(resource_id) do
    case :ets.lookup(:resources, resource_id) do
      [{_, r}] -> r.owner_id
      []       -> nil
    end
  end

  defp emit_audit_event(actor_id, action, resource_id) do
    event = %{
      actor_id:    actor_id,
      action:      action,
      resource_id: resource_id,
      occurred_at: DateTime.utc_now()
    }
    :ets.insert(:access_audit_log, {generate_id(), event})
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16()
  end
end
```
