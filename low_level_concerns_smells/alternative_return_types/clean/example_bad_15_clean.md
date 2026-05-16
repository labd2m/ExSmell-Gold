```elixir
defmodule MyApp.Access.PermissionChecker do
  @moduledoc """
  Evaluates whether a subject (user or service account) holds the required
  permission for a given resource. Integrates with the policy engine and
  supports audit logging of access decisions.
  """

  alias MyApp.Access.PolicyEngine
  alias MyApp.Access.AuditLog
  alias MyApp.Access.RoleResolver

  @admin_role :super_admin
  @audit_decisions [:deny, :error]

  defmodule AccessDeniedError do
    defexception [:subject_id, :permission, :resource_id, :message]

    def exception(opts) do
      %__MODULE__{
        subject_id: opts[:subject_id],
        permission: opts[:permission],
        resource_id: opts[:resource_id],
        message: "Access denied: #{opts[:permission]} on #{opts[:resource_id]}"
      }
    end
  end

  def check(subject_id, permission, opts \\ []) when is_list(opts) do
    on_deny = Keyword.get(opts, :on_deny, :tuple)
    resource_id = Keyword.get(opts, :resource_id, :global)
    log_decision = Keyword.get(opts, :log, false)
    bypass_for_admin = Keyword.get(opts, :bypass_for_admin, true)

    roles = RoleResolver.resolve(subject_id)

    allowed =
      if bypass_for_admin and @admin_role in roles do
        true
      else
        PolicyEngine.evaluate(subject_id, permission, resource_id, roles)
      end

    if log_decision and not allowed do
      AuditLog.record(:access_denied, %{
        subject_id: subject_id,
        permission: permission,
        resource_id: resource_id
      })
    end

    case on_deny do
      :boolean ->
        allowed

      :tuple ->
        if allowed do
          {:ok, :allowed}
        else
          {:error, :denied}
        end

      :raise ->
        if allowed do
          {:ok, :allowed}
        else
          raise AccessDeniedError,
            subject_id: subject_id,
            permission: permission,
            resource_id: resource_id
        end
    end
  end

  def check_all(subject_id, permissions, opts \\ []) do
    Enum.all?(permissions, fn perm ->
      check(subject_id, perm, Keyword.put(opts, :on_deny, :boolean))
    end)
  end

  def check_any(subject_id, permissions, opts \\ []) do
    Enum.any?(permissions, fn perm ->
      check(subject_id, perm, Keyword.put(opts, :on_deny, :boolean))
    end)
  end

  def effective_permissions(subject_id) do
    roles = RoleResolver.resolve(subject_id)
    PolicyEngine.permissions_for_roles(roles)
  end
end
```
