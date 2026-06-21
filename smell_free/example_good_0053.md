```elixir
defmodule Accounts.User do
  @moduledoc """
  Ecto schema and changeset functions for user accounts. All external
  input must pass through a named changeset before reaching the database.
  The module exposes distinct changesets for registration, profile updates,
  and email confirmation to keep each concern narrow and testable.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          email: String.t() | nil,
          display_name: String.t() | nil,
          hashed_password: String.t() | nil,
          role: String.t() | nil,
          confirmed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :email, :string
    field :display_name, :string
    field :password, :string, virtual: true
    field :hashed_password, :string
    field :role, :string, default: "viewer"
    field :confirmed_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @valid_roles ~w(admin editor viewer)
  @max_name_length 80
  @min_password_length 12

  @doc """
  Changeset for creating a new user account. Validates email uniqueness,
  password strength, and role membership.
  """
  @spec registration_changeset(t(), map()) :: Ecto.Changeset.t()
  def registration_changeset(%__MODULE__{} = user, attrs) do
    user
    |> cast(attrs, [:email, :password, :display_name, :role])
    |> validate_required([:email, :password, :display_name])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "must be a valid email")
    |> validate_length(:display_name, max: @max_name_length)
    |> validate_length(:password, min: @min_password_length)
    |> validate_inclusion(:role, @valid_roles)
    |> unique_constraint(:email)
    |> hash_password()
  end

  @doc """
  Changeset for updating display name and role. Password changes require
  a dedicated flow outside this changeset.
  """
  @spec profile_changeset(t(), map()) :: Ecto.Changeset.t()
  def profile_changeset(%__MODULE__{} = user, attrs) do
    user
    |> cast(attrs, [:display_name, :role])
    |> validate_required([:display_name])
    |> validate_length(:display_name, max: @max_name_length)
    |> validate_inclusion(:role, @valid_roles)
  end

  @doc """
  Changeset for confirming the user's email address. Sets `confirmed_at`
  to the current UTC timestamp truncated to second precision.
  """
  @spec confirmation_changeset(t()) :: Ecto.Changeset.t()
  def confirmation_changeset(%__MODULE__{} = user) do
    confirmed_at = DateTime.utc_now() |> DateTime.truncate(:second)
    change(user, confirmed_at: confirmed_at)
  end

  defp hash_password(%Ecto.Changeset{valid?: true} = changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        changeset
        |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
        |> delete_change(:password)
    end
  end

  defp hash_password(changeset), do: changeset
end
```
