# File: `example_good_19.md`

```elixir
defmodule Accounts.UserContext do
  @moduledoc """
  Context module for user account management.

  Encapsulates all user-related database operations and domain logic
  within a single cohesive module, exposing a stable public API and
  keeping Ecto concerns internal.
  """

  import Ecto.Query, warn: false

  alias Accounts.Repo
  alias Accounts.User
  alias Accounts.User.{RegistrationChangeset, ProfileChangeset, PasswordChangeset}

  @type user_id :: Ecto.UUID.t()
  @type email :: String.t()
  @type user_result :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}

  @doc """
  Registers a new user with the provided registration attributes.

  Returns `{:ok, user}` on success, or `{:error, changeset}` with
  validation errors.
  """
  @spec register(map()) :: user_result()
  def register(attrs) when is_map(attrs) do
    attrs
    |> RegistrationChangeset.build()
    |> Repo.insert()
  end

  @doc """
  Retrieves a user by ID.

  Returns `{:ok, user}` or `{:error, :not_found}`.
  """
  @spec fetch(user_id()) :: {:ok, User.t()} | {:error, :not_found}
  def fetch(user_id) when is_binary(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Retrieves a user by email address.

  Returns `{:ok, user}` or `{:error, :not_found}`.
  """
  @spec fetch_by_email(email()) :: {:ok, User.t()} | {:error, :not_found}
  def fetch_by_email(email) when is_binary(email) do
    case Repo.get_by(User, email: String.downcase(email)) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Updates a user's profile fields.

  Returns `{:ok, updated_user}` or `{:error, changeset}`.
  """
  @spec update_profile(User.t(), map()) :: user_result()
  def update_profile(%User{} = user, attrs) when is_map(attrs) do
    user
    |> ProfileChangeset.build(attrs)
    |> Repo.update()
  end

  @doc """
  Changes a user's password after verifying the current one.

  Returns `:ok` on success, `{:error, :wrong_password}` if the current
  password does not match, or `{:error, changeset}` for validation errors.
  """
  @spec change_password(User.t(), String.t(), String.t()) ::
          :ok | {:error, :wrong_password} | {:error, Ecto.Changeset.t()}
  def change_password(%User{} = user, current_password, new_password)
      when is_binary(current_password) and is_binary(new_password) do
    if verify_password(user, current_password) do
      apply_password_change(user, new_password)
    else
      {:error, :wrong_password}
    end
  end

  @doc """
  Marks a user's email address as verified.
  """
  @spec verify_email(User.t()) :: user_result()
  def verify_email(%User{email_verified: true} = user), do: {:ok, user}

  def verify_email(%User{} = user) do
    user
    |> User.verify_email_changeset()
    |> Repo.update()
  end

  @doc """
  Soft-deletes a user account by setting a `deactivated_at` timestamp.

  Returns `{:ok, user}` or `{:error, reason}`.
  """
  @spec deactivate(User.t()) :: user_result()
  def deactivate(%User{deactivated_at: nil} = user) do
    user
    |> User.deactivation_changeset(%{deactivated_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def deactivate(%User{}) do
    {:error, :already_deactivated}
  end

  @doc """
  Searches for active users whose display names or emails match the
  given query string. Returns at most `limit` results.
  """
  @spec search(String.t(), pos_integer()) :: [User.t()]
  def search(query, limit) when is_binary(query) and is_integer(limit) and limit > 0 do
    pattern = "%#{sanitize_pattern(query)}%"

    User
    |> where([u], is_nil(u.deactivated_at))
    |> where([u], ilike(u.display_name, ^pattern) or ilike(u.email, ^pattern))
    |> limit(^limit)
    |> order_by([u], asc: u.display_name)
    |> Repo.all()
  end

  defp verify_password(%User{hashed_password: hash}, password) do
    Argon2.verify_pass(password, hash)
  end

  defp apply_password_change(user, new_password) do
    case user |> PasswordChangeset.build(%{password: new_password}) |> Repo.update() do
      {:ok, _user} -> :ok
      {:error, _changeset} = error -> error
    end
  end

  defp sanitize_pattern(query) do
    String.replace(query, ~r/[%_\\]/, "")
  end
end
```
