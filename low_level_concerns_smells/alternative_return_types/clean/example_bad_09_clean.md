```elixir
defmodule MyApp.Accounts.UserManager do
  @moduledoc """
  User management operations: lookup, creation, role assignment, and
  profile updates. Used across authentication, billing, and admin modules.
  """

  alias MyApp.Repo
  alias MyApp.Accounts.User
  alias MyApp.Accounts.RolePolicy
  alias MyApp.Accounts.AuditLog

  @default_role :viewer
  @lockout_threshold 5

  defmodule User do
    defstruct [
      :id, :email, :display_name, :role,
      :locked, :failed_attempts, :inserted_at, :updated_at
    ]
  end

  def lookup(identifier, opts \\ []) when is_list(opts) do
    fields = Keyword.get(opts, :fields, :all)
    by = Keyword.get(opts, :by, :id)

    user =
      case by do
        :id -> Repo.get(User, identifier)
        :email -> Repo.get_by(User, email: String.downcase(identifier))
        :display_name -> Repo.get_by(User, display_name: identifier)
      end

    case user do
      nil ->
        {:error, :not_found}

      found ->
        result =
          case fields do
            :all ->
              found

            :email ->
              found.email

            field_list when is_list(field_list) ->
              Map.take(found, field_list)
          end

        {:ok, result}
    end
  end
  
  def create(attrs) do
    user = %User{
      id: generate_id(),
      email: String.downcase(attrs[:email]),
      display_name: attrs[:display_name],
      role: attrs[:role] || @default_role,
      locked: false,
      failed_attempts: 0,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    with :ok <- validate_email_unique(user.email),
         :ok <- RolePolicy.validate(user.role) do
      Repo.insert(user)
    end
  end

  def assign_role(user_id, role, assigner_id) do
    with {:ok, user} <- lookup(user_id),
         :ok <- RolePolicy.can_assign?(assigner_id, role) do
      updated = %{user | role: role, updated_at: DateTime.utc_now()}
      Repo.update(updated)
      AuditLog.record(:role_assigned, %{user_id: user_id, role: role, by: assigner_id})
      {:ok, updated}
    end
  end

  def lock(user_id, reason) do
    with {:ok, user} <- lookup(user_id) do
      updated = %{user | locked: true, updated_at: DateTime.utc_now()}
      Repo.update(updated)
      AuditLog.record(:account_locked, %{user_id: user_id, reason: reason})
      {:ok, updated}
    end
  end

  def record_failed_attempt(user_id) do
    with {:ok, user} <- lookup(user_id) do
      updated = %{user | failed_attempts: user.failed_attempts + 1}

      if updated.failed_attempts >= @lockout_threshold do
        lock(user_id, :too_many_failed_attempts)
      else
        Repo.update(updated)
        {:ok, updated}
      end
    end
  end

  defp validate_email_unique(email) do
    case Repo.get_by(User, email: email) do
      nil -> :ok
      _ -> {:error, :email_taken}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
```
