```elixir
defmodule Accounts.Onboarding do
  @moduledoc """
  Orchestrates the multi-step account creation flow for new users.

  Provisioning creates a user record, a default workspace, and a default role
  assignment in a single Ecto transaction. A welcome notification is dispatched
  as the final step within the same transaction boundary.
  """

  import Ecto.Query, only: [from: 2]
  alias Ecto.Multi
  alias Accounts.{Repo, User, Workspace, UserRole}
  alias Accounts.Notifications

  @type registration_attrs :: %{
          required(:email) => String.t(),
          required(:name) => String.t(),
          optional(:plan) => :free | :pro | :enterprise,
          optional(:locale) => String.t()
        }

  @type registration_result ::
          {:ok, %{user: User.t(), workspace: Workspace.t()}}
          | {:error, atom(), Ecto.Changeset.t(), map()}

  @doc """
  Registers a new user and provisions all associated resources atomically.
  """
  @spec register(registration_attrs()) :: registration_result()
  def register(attrs) when is_map(attrs) do
    plan = Map.get(attrs, :plan, :free)

    Multi.new()
    |> Multi.insert(:user, User.registration_changeset(%User{}, attrs))
    |> Multi.insert(:workspace, &provision_workspace(&1.user, plan))
    |> Multi.insert(:role, &assign_default_role(&1.user))
    |> Multi.run(:notification, &send_welcome_email/2)
    |> Repo.transaction()
  end

  @doc """
  Deactivates a user account, preventing future logins.
  """
  @spec deactivate(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def deactivate(%User{} = user) do
    user
    |> User.deactivation_changeset()
    |> Repo.update()
  end

  @doc """
  Returns a paginated list of active users ordered by registration date.
  """
  @spec list_active(keyword()) :: [User.t()]
  def list_active(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    page = Keyword.get(opts, :page, 1)
    offset = (page - 1) * limit

    from(u in User,
      where: u.active == true,
      order_by: [asc: u.inserted_at],
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  @doc "Returns the total count of registered active users."
  @spec active_count() :: non_neg_integer()
  def active_count do
    from(u in User, where: u.active == true, select: count(u.id))
    |> Repo.one()
  end

  defp provision_workspace(%User{id: user_id, name: name}, plan) do
    Workspace.changeset(%Workspace{}, %{
      owner_id: user_id,
      name: "#{name}'s Workspace",
      plan: plan
    })
  end

  defp assign_default_role(%User{id: user_id}) do
    UserRole.changeset(%UserRole{}, %{user_id: user_id, role: :member})
  end

  defp send_welcome_email(_repo, %{user: user}) do
    case Notifications.deliver_welcome(user) do
      :ok -> {:ok, :delivered}
      {:error, reason} -> {:error, reason}
    end
  end
end
```
