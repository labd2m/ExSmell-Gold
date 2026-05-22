```elixir
defmodule UserManager do
  @moduledoc """
  Manages user account lifecycle including creation, updates, role assignments,
  and soft-deletion for the platform's identity layer.
  """

  alias UserManager.{Account, AuditLog, Repo, RoleSet}
  require Logger

  @allowed_update_fields ~w(email display_name locale timezone)a
  @password_min_length 12

  @doc """
  Creates a new user account with the provided attributes.
  Sends a confirmation email upon successful creation.
  """
  def create_account(%{email: email, password: password} = attrs) do
    with :ok <- validate_email(email),
         :ok <- validate_password_strength(password),
         {:ok, hashed_pw} <- hash_password(password),
         {:ok, account} <- Repo.insert_account(Map.put(attrs, :password_hash, hashed_pw)) do
      Logger.info("Account created: #{account.id}")
      {:ok, account}
    end
  end

  # Updates mutable fields on an existing user account.
  #
  # Parameters:
  #   account_id - binary, the account's UUID
  #   changes    - map containing a subset of updatable fields:
  #                  :email        (binary)
  #                  :display_name (binary)
  #                  :locale       (binary, e.g. "en-GB")
  #                  :timezone     (binary, e.g. "Europe/London")
  #
  # Behaviour:
  #   - Unknown or restricted fields in `changes` are silently filtered out.
  #   - If :email is being changed, email uniqueness is re-validated.
  #   - All modifications are written to the audit log.
  #
  # Returns {:ok, updated_account} or {:error, reason}.
  def update_account(account_id, changes) when is_binary(account_id) and is_map(changes) do
    safe_changes = Map.take(changes, @allowed_update_fields)

    with {:ok, account} <- Repo.fetch_account(account_id),
         :ok <- maybe_validate_email(safe_changes, account),
         {:ok, updated} <- Repo.update_account(account_id, safe_changes) do
      AuditLog.record(:account_updated, account_id, safe_changes)
      {:ok, updated}
    end
  end

  @doc """
  Assigns one or more roles to an account. Roles are additive; existing roles
  are preserved.
  """
  def assign_roles(account_id, roles) when is_binary(account_id) and is_list(roles) do
    with {:ok, account} <- Repo.fetch_account(account_id) do
      merged = RoleSet.merge(account.roles, roles)
      Repo.update_account(account_id, %{roles: merged})
    end
  end

  @doc """
  Revokes one or more roles from an account.
  """
  def revoke_roles(account_id, roles) when is_binary(account_id) and is_list(roles) do
    with {:ok, account} <- Repo.fetch_account(account_id) do
      remaining = RoleSet.remove(account.roles, roles)
      Repo.update_account(account_id, %{roles: remaining})
    end
  end

  @doc """
  Soft-deletes an account by marking it as deactivated without removing the record.
  """
  def deactivate_account(account_id) when is_binary(account_id) do
    with {:ok, _account} <- Repo.fetch_account(account_id) do
      Repo.update_account(account_id, %{status: :deactivated, deactivated_at: DateTime.utc_now()})
      AuditLog.record(:account_deactivated, account_id, %{})
      :ok
    end
  end

  @doc """
  Reactivates a previously deactivated account.
  """
  def reactivate_account(account_id) when is_binary(account_id) do
    with {:ok, %Account{status: :deactivated}} <- Repo.fetch_account(account_id) do
      Repo.update_account(account_id, %{status: :active, deactivated_at: nil})
    else
      {:ok, %Account{status: :active}} -> {:error, :already_active}
      error -> error
    end
  end

  defp validate_email(email) do
    if String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/), do: :ok, else: {:error, :invalid_email}
  end

  defp validate_password_strength(pw) when byte_size(pw) >= @password_min_length, do: :ok
  defp validate_password_strength(_), do: {:error, :password_too_short}

  defp hash_password(pw), do: {:ok, Base.encode64(:crypto.hash(:sha256, pw))}

  defp maybe_validate_email(%{email: new_email}, %Account{email: old_email})
       when new_email != old_email,
       do: validate_email(new_email)

  defp maybe_validate_email(_changes, _account), do: :ok
end
```
