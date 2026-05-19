```elixir
defmodule UserManagement.Role do
  defstruct [:id, :name, :permissions, :scope, :assigned_at, :assigned_by]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          permissions: [String.t()],
          scope: String.t(),
          assigned_at: DateTime.t(),
          assigned_by: String.t()
        }
end

defmodule UserManagement.GroupMembership do
  defstruct [:group_id, :group_name, :joined_at, :role_in_group]

  @type t :: %__MODULE__{
          group_id: String.t(),
          group_name: String.t(),
          joined_at: DateTime.t(),
          role_in_group: :member | :admin | :owner
        }
end

defmodule UserManagement.ActivityRecord do
  defstruct [:action, :resource, :occurred_at, :ip, :success]

  @type t :: %__MODULE__{
          action: String.t(),
          resource: String.t(),
          occurred_at: DateTime.t(),
          ip: String.t(),
          success: boolean()
        }
end

defmodule UserManagement.User do
  @enforce_keys [:id, :email, :status, :roles, :groups, :recent_activity]
  defstruct [
    :id,
    :email,
    :full_name,
    :department,
    :status,
    :created_at,
    :last_login_at,
    :roles,
    :groups,
    :recent_activity,
    :mfa_enabled,
    :profile
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          email: String.t(),
          full_name: String.t(),
          department: String.t(),
          status: :active | :suspended | :pending | :deleted,
          created_at: DateTime.t(),
          last_login_at: DateTime.t() | nil,
          roles: [UserManagement.Role.t()],
          groups: [UserManagement.GroupMembership.t()],
          recent_activity: [UserManagement.ActivityRecord.t()],
          mfa_enabled: boolean(),
          profile: map()
        }
end

defmodule UserManagement.UserRepository do
  @moduledoc "Provides access to the full user directory."

  @spec list_all :: [UserManagement.User.t()]
  def list_all do
    now = DateTime.utc_now()
    departments = ["Engineering", "Product", "Sales", "HR", "Finance", "Legal", "Marketing"]

    Enum.map(1..30_000, fn n ->
      %UserManagement.User{
        id: "usr_#{n}",
        email: "user.#{n}@enterprise.example.com",
        full_name: "User #{n} Name",
        department: Enum.random(departments),
        status: Enum.random([:active, :active, :active, :suspended, :pending]),
        created_at: DateTime.add(now, -:rand.uniform(365 * 3) * 86_400, :second),
        last_login_at: DateTime.add(now, -:rand.uniform(30) * 86_400, :second),
        mfa_enabled: rem(n, 3) != 0,
        profile: %{
          title: "Specialist #{rem(n, 10) + 1}",
          location: Enum.random(["New York", "London", "São Paulo", "Berlin", "Singapore"]),
          manager_id: "usr_#{max(1, n - 10)}",
          hire_date: Date.add(Date.utc_today(), -:rand.uniform(1000))
        },
        roles:
          Enum.map(1..5, fn r ->
            %UserManagement.Role{
              id: "role_#{rem(n * r, 100) + 1}",
              name: Enum.random(["viewer", "editor", "admin", "billing_admin", "auditor"]),
              permissions:
                Enum.map(1..10, fn p ->
                  "permission:resource_#{rem(p, 20)}:#{Enum.random(["read", "write", "delete"])}"
                end),
              scope: "tenant:#{rem(n, 200) + 1}",
              assigned_at: DateTime.add(now, -:rand.uniform(200) * 86_400, :second),
              assigned_by: "usr_#{rem(n, 50) + 1}"
            }
          end),
        groups:
          Enum.map(1..8, fn g ->
            %UserManagement.GroupMembership{
              group_id: "grp_#{rem(n * g, 300) + 1}",
              group_name: "Group #{rem(n * g, 300) + 1}",
              joined_at: DateTime.add(now, -:rand.uniform(100) * 86_400, :second),
              role_in_group: Enum.random([:member, :member, :admin, :owner])
            }
          end),
        recent_activity:
          Enum.map(1..20, fn a ->
            %UserManagement.ActivityRecord{
              action: Enum.random(["login", "update_profile", "change_role", "export_data"]),
              resource: "resource:#{rem(a, 30)}",
              occurred_at: DateTime.add(now, -a * 3600, :second),
              ip: "10.#{rem(n, 255)}.#{rem(a, 255)}.1",
              success: rem(a, 10) != 0
            }
          end)
      }
    end)
  end
end

defmodule UserManagement.AuditWorker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, [], opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:full_user_list, users}, _state) do
    {:noreply, users}
  end
end

defmodule UserManagement.RoleAuditor do
  @moduledoc """
  Runs periodic role audits by forwarding the full user roster to
  an audit worker that checks for privilege escalations and stale access.
  """

  require Logger

  @spec dispatch_full_user_list(pid()) :: :ok
  def dispatch_full_user_list(audit_worker_pid) do
    Logger.info("Loading full user directory for audit...")

    users = UserManagement.UserRepository.list_all()

    Logger.info("Loaded #{length(users)} users. Dispatching to audit worker...")

    send(audit_worker_pid, {:full_user_list, users})

    Logger.info("Full user list dispatched for audit.")
    :ok
  end
end
```
