```elixir
defmodule Accounts.User do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          email: String.t() | nil,
          display_name: String.t() | nil,
          role: :admin | :member | :viewer,
          active: boolean()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :email, :string
    field :display_name, :string
    field :role, Ecto.Enum, values: [:admin, :member, :viewer], default: :member
    field :active, :boolean, default: true
    timestamps(type: :utc_datetime)
  end

  @spec creation_changeset(t(), map()) :: Ecto.Changeset.t()
  def creation_changeset(user, params) do
    user
    |> cast(params, [:email, :display_name, :role])
    |> validate_required([:email, :display_name])
    |> validate_format(:email, ~r/\A[^@\s]+@[^@\s]+\z/)
    |> validate_length(:display_name, min: 2, max: 100)
    |> unique_constraint(:email)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(user, params) do
    user
    |> cast(params, [:display_name, :role])
    |> validate_length(:display_name, min: 2, max: 100)
    |> validate_inclusion(:role, [:admin, :member, :viewer])
  end

  @spec deactivation_changeset(t()) :: Ecto.Changeset.t()
  def deactivation_changeset(user) do
    change(user, active: false)
  end
end

defmodule Accounts.UserQuery do
  @moduledoc false

  import Ecto.Query

  alias Accounts.User

  @spec active(Ecto.Queryable.t()) :: Ecto.Query.t()
  def active(query), do: from(u in query, where: u.active == true)

  @spec by_role(Ecto.Queryable.t(), atom()) :: Ecto.Query.t()
  def by_role(query, role), do: from(u in query, where: u.role == ^role)

  @spec ordered_by_name(Ecto.Queryable.t()) :: Ecto.Query.t()
  def ordered_by_name(query), do: from(u in query, order_by: [asc: u.display_name])

  @spec count_by_role(atom()) :: Ecto.Query.t()
  def count_by_role(role) do
    from u in User,
      where: u.role == ^role and u.active == true,
      select: count(u.id)
  end
end

defmodule Accounts do
  @moduledoc """
  Public boundary for account lifecycle management.

  All user persistence and query concerns are encapsulated here.
  External callers interact exclusively through this module's typed API;
  schema details and query composition remain internal.
  """

  import Ecto.Query, warn: false

  alias Accounts.{Repo, User, UserQuery}

  @spec register_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(params) do
    %User{}
    |> User.creation_changeset(params)
    |> Repo.insert()
  end

  @spec update_profile(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_profile(%User{} = user, params) do
    user
    |> User.update_changeset(params)
    |> Repo.update()
  end

  @spec get_user(Ecto.UUID.t()) :: {:ok, User.t()} | {:error, :not_found}
  def get_user(id) when is_binary(id) do
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

  @spec list_active_by_role(:admin | :member | :viewer) :: [User.t()]
  def list_active_by_role(role) when role in [:admin, :member, :viewer] do
    User
    |> UserQuery.active()
    |> UserQuery.by_role(role)
    |> UserQuery.ordered_by_name()
    |> Repo.all()
  end

  @spec deactivate_user(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def deactivate_user(%User{} = user) do
    user
    |> User.deactivation_changeset()
    |> Repo.update()
  end

  @spec admin_count() :: non_neg_integer()
  def admin_count do
    UserQuery.count_by_role(:admin) |> Repo.one() |> Kernel.||(0)
  end
end
```
