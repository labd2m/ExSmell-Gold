**File:** `example_good_1176.md`

```elixir
defmodule Workspaces.Workspace do
  @moduledoc "Schema for a tenant workspace record."

  use Ecto.Schema
  import Ecto.Changeset

  @type plan :: :free | :pro | :enterprise
  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          slug: String.t(),
          name: String.t(),
          plan: plan(),
          owner_id: String.t(),
          member_limit: pos_integer(),
          suspended_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "workspaces" do
    field :slug, :string
    field :name, :string
    field :plan, Ecto.Enum, values: [:free, :pro, :enterprise]
    field :owner_id, :string
    field :member_limit, :integer
    field :suspended_at, :utc_datetime_usec
    timestamps()
  end

  @spec creation_changeset(t(), map()) :: Ecto.Changeset.t()
  def creation_changeset(ws, attrs) do
    ws
    |> cast(attrs, [:slug, :name, :plan, :owner_id])
    |> validate_required([:slug, :name, :plan, :owner_id])
    |> validate_format(:slug, ~r/^[a-z0-9\-]{3,48}$/, message: "must be 3-48 lowercase letters, numbers, or hyphens")
    |> validate_length(:name, min: 1, max: 128)
    |> unique_constraint(:slug)
    |> put_member_limit()
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(ws, attrs) do
    ws
    |> cast(attrs, [:name, :plan])
    |> validate_required([:name, :plan])
    |> validate_length(:name, min: 1, max: 128)
    |> put_member_limit()
  end

  defp put_member_limit(changeset) do
    case get_field(changeset, :plan) do
      :free -> put_change(changeset, :member_limit, 5)
      :pro -> put_change(changeset, :member_limit, 50)
      :enterprise -> put_change(changeset, :member_limit, 500)
      _ -> changeset
    end
  end
end

defmodule Workspaces.Member do
  @moduledoc "Schema representing a user's membership in a workspace."

  use Ecto.Schema
  import Ecto.Changeset

  @type role :: :owner | :admin | :member | :viewer
  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          workspace_id: Ecto.UUID.t(),
          user_id: String.t(),
          role: role()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "workspace_members" do
    field :workspace_id, :binary_id
    field :user_id, :string
    field :role, Ecto.Enum, values: [:owner, :admin, :member, :viewer]
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(member, attrs) do
    member
    |> cast(attrs, [:workspace_id, :user_id, :role])
    |> validate_required([:workspace_id, :user_id, :role])
    |> unique_constraint([:workspace_id, :user_id])
  end
end

defmodule Workspaces do
  @moduledoc "Context for managing workspaces and their memberships."

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Workspaces.{Member, Workspace}

  @spec create(map()) :: {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    Repo.transaction(fn ->
      with {:ok, workspace} <- insert_workspace(attrs),
           {:ok, _member} <- add_member(workspace, attrs.owner_id, :owner) do
        workspace
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec get_by_slug(String.t()) :: {:ok, Workspace.t()} | {:error, :not_found}
  def get_by_slug(slug) when is_binary(slug) do
    case Repo.get_by(Workspace, slug: slug) do
      nil -> {:error, :not_found}
      ws -> {:ok, ws}
    end
  end

  @spec update(Workspace.t(), map()) :: {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def update(%Workspace{} = workspace, attrs) do
    workspace
    |> Workspace.update_changeset(attrs)
    |> Repo.update()
  end

  @spec add_member(Workspace.t(), String.t(), Member.role()) ::
          {:ok, Member.t()} | {:error, :member_limit_reached} | {:error, Ecto.Changeset.t()}
  def add_member(%Workspace{} = workspace, user_id, role) do
    current_count = count_members(workspace.id)

    if current_count >= workspace.member_limit do
      {:error, :member_limit_reached}
    else
      %Member{}
      |> Member.changeset(%{workspace_id: workspace.id, user_id: user_id, role: role})
      |> Repo.insert()
    end
  end

  @spec remove_member(Ecto.UUID.t(), String.t()) :: :ok | {:error, :not_found}
  def remove_member(workspace_id, user_id) do
    case Repo.get_by(Member, workspace_id: workspace_id, user_id: user_id) do
      nil -> {:error, :not_found}
      member -> Repo.delete(member) && :ok
    end
  end

  defp insert_workspace(attrs) do
    %Workspace{}
    |> Workspace.creation_changeset(attrs)
    |> Repo.insert()
  end

  defp count_members(workspace_id) do
    Member
    |> where([m], m.workspace_id == ^workspace_id)
    |> Repo.aggregate(:count, :id)
  end
end
```
