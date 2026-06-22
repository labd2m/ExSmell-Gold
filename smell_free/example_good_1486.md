```elixir
defmodule Accounts.UserContext do
  @moduledoc """
  Public API for user lifecycle operations within the Accounts bounded context.
  Delegates persistence to `Accounts.Repo` and enforces business rules before mutations.
  """

  alias Accounts.{User, Repo, PasswordHasher, EmailValidator}

  @type registration_params :: %{
    name: String.t(),
    email: String.t(),
    password: String.t()
  }

  @spec register_user(registration_params()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t() | String.t()}
  def register_user(%{email: email, password: password, name: name} = _params) do
    with :ok <- EmailValidator.validate(email),
         :ok <- validate_password_strength(password),
         {:ok, hashed} <- PasswordHasher.hash(password) do
      %{name: name, email: String.downcase(email), password_hash: hashed}
      |> User.creation_changeset()
      |> Repo.insert()
    end
  end

  @spec update_profile(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_profile(%User{} = user, params) when is_map(params) do
    user
    |> User.profile_changeset(params)
    |> Repo.update()
  end

  @spec change_password(User.t(), String.t(), String.t()) ::
          {:ok, User.t()} | {:error, String.t() | Ecto.Changeset.t()}
  def change_password(%User{} = user, current_password, new_password)
      when is_binary(current_password) and is_binary(new_password) do
    with :ok <- PasswordHasher.verify(current_password, user.password_hash),
         :ok <- validate_password_strength(new_password),
         {:ok, hashed} <- PasswordHasher.hash(new_password) do
      user
      |> User.password_changeset(%{password_hash: hashed})
      |> Repo.update()
    end
  end

  @spec deactivate(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def deactivate(%User{} = user) do
    user
    |> User.status_changeset(%{active: false, deactivated_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @spec get_by_email(String.t()) :: {:ok, User.t()} | {:error, :not_found}
  def get_by_email(email) when is_binary(email) do
    case Repo.get_by(User, email: String.downcase(email)) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @spec authenticate(String.t(), String.t()) :: {:ok, User.t()} | {:error, :invalid_credentials}
  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    with {:ok, user} <- get_by_email(email),
         :ok <- PasswordHasher.verify(password, user.password_hash) do
      {:ok, user}
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  @spec validate_password_strength(String.t()) :: :ok | {:error, String.t()}
  defp validate_password_strength(password) when byte_size(password) < 8 do
    {:error, "Password must be at least 8 characters long"}
  end

  defp validate_password_strength(password) do
    has_upper = String.match?(password, ~r/[A-Z]/)
    has_digit = String.match?(password, ~r/[0-9]/)

    if has_upper and has_digit do
      :ok
    else
      {:error, "Password must contain at least one uppercase letter and one digit"}
    end
  end
end
```
