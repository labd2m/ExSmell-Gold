```elixir
defmodule Accounts.UserContext do
  @moduledoc """
  Manages user lifecycle operations: registration, profile updates,
  deactivation, and credential verification against the accounts domain.
  """

  alias Accounts.{Repo, User, PasswordHasher, EmailVerification}
  alias Ecto.Multi

  @type registration_params :: %{
          email: String.t(),
          password: String.t(),
          display_name: String.t()
        }

  @spec register_user(registration_params()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | atom()}
  def register_user(params) do
    Multi.new()
    |> Multi.insert(:user, User.registration_changeset(%User{}, params))
    |> Multi.run(:verification, fn _repo, %{user: user} ->
      EmailVerification.send_confirmation(user)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _changes} -> {:error, changeset}
      {:error, :verification, reason, _changes} -> {:error, reason}
    end
  end

  @spec verify_credentials(String.t(), String.t()) :: {:ok, User.t()} | {:error, :unauthorized}
  def verify_credentials(email, password) when is_binary(email) and is_binary(password) do
    case Repo.get_by(User, email: email, active: true) do
      nil ->
        PasswordHasher.dummy_check()
        {:error, :unauthorized}

      user ->
        verify_password(user, password)
    end
  end

  @spec update_profile(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_profile(%User{} = user, params) do
    user
    |> User.profile_changeset(params)
    |> Repo.update()
  end

  @spec deactivate(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def deactivate(%User{} = user) do
    user
    |> User.deactivation_changeset()
    |> Repo.update()
  end

  @spec get_user(pos_integer()) :: {:ok, User.t()} | {:error, :not_found}
  def get_user(id) when is_integer(id) do
    case Repo.get(User, id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @spec verify_password(User.t(), String.t()) :: {:ok, User.t()} | {:error, :unauthorized}
  defp verify_password(user, password) do
    if PasswordHasher.valid?(password, user.password_hash) do
      {:ok, user}
    else
      {:error, :unauthorized}
    end
  end
end
```
