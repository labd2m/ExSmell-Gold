# Code Smell Annotation

- **Smell name:** Large Class (Large Module)
- **Expected smell location:** The entire `UserManager` module
- **Affected function(s):** `create_user/1`, `update_profile/2`, `deactivate_user/2`, `reactivate_user/1`, `assign_role/2`, `revoke_role/2`, `has_permission?/2`, `list_users/1`, `search_users/2`, `export_users_csv/1`, `record_audit_event/3`
- **Short explanation:** `UserManager` conflates user CRUD, profile management, role and permission assignment, user search and listing, CSV export, and audit event recording. These are separate concerns belonging in modules like `UserProfiles`, `RoleManager`, `PermissionChecker`, `UserSearch`, `UserExport`, and `AuditLog`.

```elixir
# VALIDATION: SMELL START - Large Class (Large Module)
# VALIDATION: This is a smell because UserManager mixes user creation and
# profile management, activation lifecycle, RBAC role assignment, permission
# checking, filtered listings, CSV export, and audit logging — each a separate
# business concern that warrants its own dedicated module.
defmodule MyApp.UserManager do
  @moduledoc """
  Handles all user management operations including profile management,
  role assignments, permissions, search, export, and audit logging.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Accounts.{User, Role, UserRole, AuditLog}
  alias MyApp.Crypto

  @permissions %{
    admin:     [:read, :write, :delete, :manage_users, :manage_billing],
    manager:   [:read, :write, :delete, :view_reports],
    analyst:   [:read, :view_reports],
    support:   [:read, :write],
    viewer:    [:read]
  }

  # -------------------------------------------------------------------
  # User CRUD
  # -------------------------------------------------------------------

  def create_user(attrs) do
    password = attrs[:password] || Crypto.random_password()
    hash     = Crypto.hash_password(password)

    changeset =
      %User{}
      |> User.changeset(Map.merge(attrs, %{password_hash: hash, status: :active}))

    case Repo.insert(changeset) do
      {:ok, user} ->
        record_audit_event(nil, :user_created, %{user_id: user.id, created_by: attrs[:created_by]})
        MyApp.Mailer.deliver(%{
          to:      user.email,
          subject: "Welcome to MyApp",
          body:    "Your account has been created. Password: #{password}"
        })
        {:ok, user}

      {:error, _} = err ->
        err
    end
  end

  def update_profile(user_id, changes) do
    user    = Repo.get!(User, user_id)
    allowed = Map.take(changes, [:first_name, :last_name, :phone, :timezone, :locale, :avatar_url])

    case Repo.update(User.changeset(user, allowed)) do
      {:ok, updated} ->
        record_audit_event(user_id, :profile_updated, %{changes: allowed})
        {:ok, updated}

      {:error, _} = err ->
        err
    end
  end

  # -------------------------------------------------------------------
  # Activation lifecycle
  # -------------------------------------------------------------------

  def deactivate_user(user_id, reason) do
    user = Repo.get!(User, user_id)

    Repo.update!(User.changeset(user, %{
      status:           :inactive,
      deactivated_at:   DateTime.utc_now(),
      deactivation_reason: reason
    }))

    record_audit_event(user_id, :user_deactivated, %{reason: reason})

    MyApp.Mailer.deliver(%{
      to:      user.email,
      subject: "Your account has been deactivated",
      body:    "Your account was deactivated. Reason: #{reason}."
    })

    :ok
  end

  def reactivate_user(user_id) do
    user = Repo.get!(User, user_id)

    Repo.update!(User.changeset(user, %{
      status:           :active,
      deactivated_at:   nil,
      deactivation_reason: nil
    }))

    record_audit_event(user_id, :user_reactivated, %{})

    MyApp.Mailer.deliver(%{
      to:      user.email,
      subject: "Your account has been reactivated",
      body:    "Good news! Your account is active again."
    })

    :ok
  end

  # -------------------------------------------------------------------
  # Role management
  # -------------------------------------------------------------------

  def assign_role(user_id, role_name) when is_atom(role_name) do
    unless Map.has_key?(@permissions, role_name) do
      raise ArgumentError, "Unknown role: #{role_name}"
    end

    role = Repo.get_by!(Role, name: to_string(role_name))

    existing = Repo.get_by(UserRole, user_id: user_id, role_id: role.id)

    unless existing do
      Repo.insert!(%UserRole{user_id: user_id, role_id: role.id, assigned_at: DateTime.utc_now()})
      record_audit_event(user_id, :role_assigned, %{role: role_name})
    end

    :ok
  end

  def revoke_role(user_id, role_name) when is_atom(role_name) do
    role = Repo.get_by!(Role, name: to_string(role_name))

    case Repo.get_by(UserRole, user_id: user_id, role_id: role.id) do
      nil        -> {:error, :role_not_assigned}
      user_role  ->
        Repo.delete!(user_role)
        record_audit_event(user_id, :role_revoked, %{role: role_name})
        :ok
    end
  end

  # -------------------------------------------------------------------
  # Permission checking
  # -------------------------------------------------------------------

  def has_permission?(%User{} = user, permission) when is_atom(permission) do
    roles = load_user_roles(user.id)

    Enum.any?(roles, fn role_name ->
      permission in Map.get(@permissions, role_name, [])
    end)
  end

  defp load_user_roles(user_id) do
    from(ur in UserRole,
      join: r in Role, on: r.id == ur.role_id,
      where: ur.user_id == ^user_id,
      select: r.name
    )
    |> Repo.all()
    |> Enum.map(&String.to_existing_atom/1)
  end

  # -------------------------------------------------------------------
  # Search and listing
  # -------------------------------------------------------------------

  def list_users(filters \\ %{}) do
    query =
      from u in User,
        where: u.status == :active,
        order_by: [asc: u.last_name, asc: u.first_name]

    query =
      if role = filters[:role] do
        from u in query,
          join: ur in UserRole, on: ur.user_id == u.id,
          join: r in Role, on: r.id == ur.role_id,
          where: r.name == ^to_string(role)
      else
        query
      end

    query =
      if created_after = filters[:created_after] do
        from u in query, where: u.inserted_at >= ^created_after
      else
        query
      end

    Repo.all(query)
  end

  def search_users(term, opts \\ []) when is_binary(term) do
    limit  = opts[:limit] || 20
    like   = "%#{term}%"

    from(u in User,
      where: ilike(u.email, ^like)
          or ilike(u.first_name, ^like)
          or ilike(u.last_name, ^like),
      order_by: [asc: u.last_name],
      limit: ^limit
    )
    |> Repo.all()
  end

  # -------------------------------------------------------------------
  # CSV export
  # -------------------------------------------------------------------

  def export_users_csv(filters \\ %{}) do
    users  = list_users(filters)
    header = "id,email,first_name,last_name,status,created_at\n"

    rows =
      Enum.map(users, fn u ->
        "#{u.id},#{u.email},#{u.first_name},#{u.last_name},#{u.status},#{u.inserted_at}\n"
      end)

    header <> Enum.join(rows)
  end

  # -------------------------------------------------------------------
  # Audit logging
  # -------------------------------------------------------------------

  def record_audit_event(user_id, event_type, metadata) do
    Repo.insert!(%AuditLog{
      user_id:     user_id,
      event_type:  event_type,
      metadata:    metadata,
      occurred_at: DateTime.utc_now()
    })
  end
end
# VALIDATION: SMELL END
```
