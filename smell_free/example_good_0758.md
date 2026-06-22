```elixir
defmodule MyApp.Accounts.RoleChangeAuditor do
  @moduledoc """
  Enforces and audits role changes across a multi-tenant hierarchy.
  Role elevation (assigning a role higher than the actor's own) is
  blocked at this boundary. Every permitted change is written to the
  audit log before the database write so that no change is unrecorded,
  even if a subsequent operation fails.

  Role changes that cross the admin boundary trigger an out-of-band
  alert via the notification system in addition to the audit entry.
  """

  alias MyApp.Repo
  alias MyApp.Accounts.{User, OrgMember}
  alias MyApp.Compliance.AuditLogger
  alias MyApp.Notifications.Dispatcher

  import Ecto.Query, warn: false

  @role_hierarchy [:viewer, :member, :manager, :admin, :owner]
  @alert_threshold :admin

  @type actor :: User.t()
  @type role :: :viewer | :member | :manager | :admin | :owner

  @doc """
  Changes the role of `target_user` in `org_id` from its current role
  to `new_role`, as authorised by `actor`. Returns `{:ok, member}` or
  a structured error.
  """
  @spec change_role(actor(), String.t(), User.t(), role()) ::
          {:ok, OrgMember.t()}
          | {:error, :self_modification}
          | {:error, :insufficient_permissions}
          | {:error, :not_a_member}
          | {:error, Ecto.Changeset.t()}
  def change_role(%User{} = actor, org_id, %User{} = target, new_role)
      when is_binary(org_id) do
    with :ok <- forbid_self_modification(actor, target),
         {:ok, actor_role} <- fetch_role(actor.id, org_id),
         :ok <- check_elevation(actor_role, new_role),
         {:ok, member} <- fetch_member(target.id, org_id) do
      AuditLogger.log(
        %{id: actor.id, type: :user},
        "role.changed",
        %{id: org_id, type: "organisation"},
        %{target_user_id: target.id, from_role: member.role, to_role: new_role}
      )

      maybe_alert_role_elevation(actor, target, org_id, member.role, new_role)

      member
      |> OrgMember.changeset(%{role: new_role})
      |> Repo.update()
    end
  end

  @spec forbid_self_modification(actor(), User.t()) :: :ok | {:error, :self_modification}
  defp forbid_self_modification(actor, target) do
    if actor.id == target.id, do: {:error, :self_modification}, else: :ok
  end

  @spec fetch_role(String.t(), String.t()) :: {:ok, role()} | {:error, :not_a_member}
  defp fetch_role(user_id, org_id) do
    case Repo.get_by(OrgMember, user_id: user_id, org_id: org_id) do
      nil -> {:error, :not_a_member}
      m -> {:ok, m.role}
    end
  end

  @spec check_elevation(role(), role()) :: :ok | {:error, :insufficient_permissions}
  defp check_elevation(actor_role, new_role) do
    if role_rank(actor_role) > role_rank(new_role), do: :ok, else: {:error, :insufficient_permissions}
  end

  @spec fetch_member(String.t(), String.t()) :: {:ok, OrgMember.t()} | {:error, :not_a_member}
  defp fetch_member(user_id, org_id) do
    case Repo.get_by(OrgMember, user_id: user_id, org_id: org_id) do
      nil -> {:error, :not_a_member}
      m -> {:ok, m}
    end
  end

  @spec maybe_alert_role_elevation(actor(), User.t(), String.t(), role(), role()) :: :ok
  defp maybe_alert_role_elevation(actor, target, org_id, old_role, new_role) do
    if role_rank(new_role) >= role_rank(@alert_threshold) and role_rank(old_role) < role_rank(@alert_threshold) do
      Dispatcher.dispatch(%{
        channels: [:email],
        recipient_email: target.email,
        subject: "Your organisation role has been elevated",
        body: "Your role in organisation #{org_id} has been changed to #{new_role} by #{actor.email}.",
        id: "role_change_#{target.id}_#{org_id}"
      })
    end

    :ok
  end

  @spec role_rank(role()) :: non_neg_integer()
  defp role_rank(role), do: Enum.find_index(@role_hierarchy, &(&1 == role)) || 0
end
```
