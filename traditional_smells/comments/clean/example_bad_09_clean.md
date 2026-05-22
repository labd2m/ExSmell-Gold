```elixir
defmodule UserManager do
  @moduledoc """
  Manages user account lifecycle operations including creation, updates,
  role assignment, and deactivation within the multi-tenant platform.
  """

  alias UserManager.{
    User,
    Role,
    AuditTrail,
    SessionStore,
    OrganizationMembership,
    BillingAccount,
    NotificationService
  }

  @doc """
  Creates a new user account and assigns default roles for the given organization.
  """
  def create_user(params, org_id) do
    Repo.transaction(fn ->
      with {:ok, user} <- User.create(params),
           {:ok, _} <- OrganizationMembership.add(user.id, org_id, :member),
           {:ok, _} <- Role.assign_default(user.id, org_id) do
        AuditTrail.record(:user_created, user.id, org_id)
        user
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Updates mutable profile fields for an existing user account.
  """
  def update_profile(user_id, params) do
    with {:ok, user} <- User.fetch(user_id),
         {:ok, updated} <- User.update(user, params) do
      AuditTrail.record(:profile_updated, user_id, nil)
      {:ok, updated}
    end
  end

  # deactivate_account/2
  #
  # Deactivates a user account and cascades the following side effects:
  #
  #   1. Marks the User record with status: :deactivated and records a
  #      deactivated_at timestamp.
  #   2. Revokes all active sessions from the SessionStore (forces logout).
  #   3. Removes all OrganizationMembership records for the user.
  #   4. Flags the BillingAccount as inactive to prevent future charges.
  #   5. Sends a confirmation email via NotificationService.
  #   6. Records an AuditTrail entry with the requesting actor's id.
  #
  # Permission requirements:
  #   `actor` must be either the user themselves (self-deactivation) or
  #   an admin. Attempting to deactivate another user without admin rights
  #   returns {:error, :forbidden}.
  #
  # Parameters:
  #   user_id - integer user to deactivate
  #   actor   - map with :id (integer) and :role (:user | :admin)
  #
  # Returns :ok or {:error, reason}.
  # inline comments to explain its cascading effects, permission model, and
  # return type. All of that information is invisible to @doc-based tooling.
  def deactivate_account(user_id, actor) do
    with :ok <- authorize_deactivation(user_id, actor),
         {:ok, user} <- User.fetch(user_id),
         {:ok, _} <- User.update(user, %{status: :deactivated, deactivated_at: DateTime.utc_now()}),
         :ok <- SessionStore.revoke_all(user_id),
         :ok <- OrganizationMembership.remove_all(user_id),
         {:ok, _} <- BillingAccount.deactivate(user_id),
         :ok <- NotificationService.send_deactivation_email(user) do
      AuditTrail.record(:account_deactivated, user_id, actor.id)
      :ok
    end
  end

  @doc """
  Reactivates a previously deactivated account.
  """
  def reactivate_account(user_id, admin_actor) do
    with :ok <- require_admin(admin_actor),
         {:ok, user} <- User.fetch(user_id),
         {:ok, _} <- User.update(user, %{status: :active, deactivated_at: nil}) do
      AuditTrail.record(:account_reactivated, user_id, admin_actor.id)
      :ok
    end
  end

  @doc """
  Assigns a role to a user within a specific organization.
  """
  def assign_role(user_id, org_id, role, admin_actor) do
    with :ok <- require_admin(admin_actor),
         {:ok, _} <- Role.assign(user_id, org_id, role) do
      AuditTrail.record(:role_assigned, user_id, admin_actor.id, %{org_id: org_id, role: role})
      :ok
    end
  end

  defp authorize_deactivation(user_id, %{id: actor_id}) when user_id == actor_id, do: :ok
  defp authorize_deactivation(_user_id, %{role: :admin}), do: :ok
  defp authorize_deactivation(_user_id, _actor), do: {:error, :forbidden}

  defp require_admin(%{role: :admin}), do: :ok
  defp require_admin(_), do: {:error, :forbidden}
end
```
