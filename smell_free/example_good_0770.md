```elixir
defmodule Accounts.UserContext do
  @moduledoc """
  The User context owns all mutations and queries for user accounts.
  Registration, profile update, email change, and deactivation are
  the supported lifecycle operations. Each flow uses its own named
  changeset to keep validation concerns isolated. All reads and writes
  pass through this context to maintain a single source of truth.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Accounts.User

  @type user_id :: String.t()
  @type register_params :: %{
          email: String.t(),
          password: String.t(),
          display_name: String.t()
        }

  @doc "Registers a new user account. Returns the user or a changeset error."
  @spec register(register_params()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register(%{email: _, password: _, display_name: _} = params) do
    %User{}
    |> User.registration_changeset(params)
    |> Repo.insert()
  end

  @doc "Fetches a user by ID."
  @spec fetch(user_id()) :: {:ok, User.t()} | {:error, :not_found}
  def fetch(user_id) when is_binary(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc "Fetches a user by email address."
  @spec fetch_by_email(String.t()) :: {:ok, User.t()} | {:error, :not_found}
  def fetch_by_email(email) when is_binary(email) do
    case Repo.get_by(User, email: String.downcase(email)) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc "Updates display name and role. Password changes require a dedicated flow."
  @spec update_profile(User.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_profile(%User{} = user, params) when is_map(params) do
    user |> User.profile_changeset(params) |> Repo.update()
  end

  @doc """
  Initiates an email change by storing the new address as pending.
  The change is not applied until the new address is verified.
  """
  @spec initiate_email_change(User.t(), String.t()) ::
          {:ok, User.t()} | {:error, :email_taken | Ecto.Changeset.t()}
  def initiate_email_change(%User{} = user, new_email) when is_binary(new_email) do
    normalised = String.downcase(new_email)

    if Repo.exists?(from(u in User, where: u.email == ^normalised and u.id != ^user.id)) do
      {:error, :email_taken}
    else
      user |> User.pending_email_changeset(%{pending_email: normalised}) |> Repo.update()
    end
  end

  @doc "Deactivates a user account. The record is preserved for audit purposes."
  @spec deactivate(User.t()) :: {:ok, User.t()} | {:error, :already_inactive | Ecto.Changeset.t()}
  def deactivate(%User{active: false}), do: {:error, :already_inactive}

  def deactivate(%User{} = user) do
    user |> User.deactivation_changeset() |> Repo.update()
  end

  @doc "Authenticates a user by email and password."
  @spec authenticate(String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_credentials | :account_inactive}
  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    with {:ok, user} <- fetch_by_email(email) do
      cond do
        not user.active -> {:error, :account_inactive}
        Bcrypt.verify_pass(password, user.hashed_password) -> {:ok, user}
        true -> {:error, :invalid_credentials}
      end
    else
      {:error, :not_found} -> {:error, :invalid_credentials}
    end
  end

  @doc "Returns a page of users sorted by registration date descending."
  @spec list(pos_integer(), pos_integer()) :: [User.t()]
  def list(page \\ 1, per_page \\ 20) when is_integer(page) and is_integer(per_page) do
    User
    |> order_by([u], desc: u.inserted_at)
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> Repo.all()
  end
end
```
