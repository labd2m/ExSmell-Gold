```elixir
defmodule Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  Schema and changeset definitions for the `users` table.
  """

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          email: String.t(),
          display_name: String.t(),
          hashed_password: String.t(),
          confirmed_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :email, :string
    field :display_name, :string
    field :hashed_password, :string
    field :password, :string, virtual: true
    field :confirmed_at, :utc_datetime
    timestamps()
  end

  @spec registration_changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :display_name, :password])
    |> validate_required([:email, :display_name, :password])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)
    |> validate_length(:display_name, min: 2, max: 60)
    |> validate_length(:password, min: 10)
    |> unique_constraint(:email)
    |> hash_password()
  end

  @spec confirmation_changeset(t() | Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def confirmation_changeset(user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    change(user, confirmed_at: now)
  end

  defp hash_password(%Ecto.Changeset{valid?: true, changes: %{password: password}} = cs) do
    put_change(cs, :hashed_password, Bcrypt.hash_pwd_salt(password))
  end

  defp hash_password(changeset), do: changeset
end

defmodule Accounts do
  import Ecto.Query

  alias Accounts.User
  alias MyApp.Repo

  @moduledoc """
  Public boundary for user account lifecycle operations.
  Covers registration, credential verification, and confirmation.
  """

  @spec register_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @spec get_user(Ecto.UUID.t()) :: {:ok, User.t()} | {:error, :not_found}
  def get_user(id) do
    case Repo.get(User, id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @spec get_user_by_email(String.t()) :: {:ok, User.t()} | {:error, :not_found}
  def get_user_by_email(email) when is_binary(email) do
    case Repo.get_by(User, email: email) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @spec authenticate(String.t(), String.t()) :: {:ok, User.t()} | {:error, :invalid_credentials}
  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    with {:ok, user} <- get_user_by_email(email),
         true <- Bcrypt.verify_pass(password, user.hashed_password) do
      {:ok, user}
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  @spec confirm_user(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def confirm_user(%User{} = user) do
    user
    |> User.confirmation_changeset()
    |> Repo.update()
  end

  @spec list_unconfirmed_users() :: [User.t()]
  def list_unconfirmed_users do
    User
    |> where([u], is_nil(u.confirmed_at))
    |> order_by([u], asc: u.inserted_at)
    |> Repo.all()
  end
end
```
