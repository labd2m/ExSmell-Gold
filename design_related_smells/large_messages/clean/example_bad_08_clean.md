```elixir
defmodule UserManagement.Permission do
  defstruct [:resource, :action, :scope, :granted_at, :granted_by]
end

defmodule UserManagement.ActivitySummary do
  defstruct [
    :last_login_at,
    :login_count_30d,
    :api_call_count_30d,
    :avg_session_duration_s,
    :feature_flags,
    :last_ip
  ]
end

defmodule UserManagement.Address do
  defstruct [:street, :city, :state, :country, :postal_code]
end

defmodule UserManagement.User do
  @enforce_keys [:id, :email, :status]
  defstruct [
    :id,
    :email,
    :status,
    :role,
    :name,
    :phone,
    :address,
    :permissions,
    :activity,
    :custom_attributes,
    :created_at,
    :updated_at,
    :gdpr_consents
  ]
end

defmodule UserManagement.UserRepo do
  @moduledoc "Simulates fetching all users for archival export."

  @spec all_inactive(non_neg_integer()) :: list(UserManagement.User.t())
  def all_inactive(inactive_days) do
    Enum.map(1..40_000, fn i ->
      %UserManagement.User{
        id: "USR-#{i}",
        email: "user#{i}@corp.example.com",
        status: :inactive,
        role: Enum.random(["viewer", "editor", "admin"]),
        name: "User #{i}",
        phone: "+5511#{String.pad_leading("#{i}", 8, "0")}",
        address: %UserManagement.Address{
          street: "Rua #{i}",
          city: "São Paulo",
          state: "SP",
          country: "BR",
          postal_code: "01#{String.pad_leading("#{rem(i, 1000)}", 6, "0")}"
        },
        permissions: Enum.map(1..8, fn j ->
          %UserManagement.Permission{
            resource: "resource_#{rem(j, 5)}",
            action: Enum.random(["read", "write", "delete"]),
            scope: "tenant_#{rem(i, 100)}",
            granted_at: DateTime.utc_now(),
            granted_by: "admin-#{rem(j, 10)}"
          }
        end),
        activity: %UserManagement.ActivitySummary{
          last_login_at: DateTime.utc_now() |> DateTime.add(-inactive_days * 86_400),
          login_count_30d: 0,
          api_call_count_30d: 0,
          avg_session_duration_s: 0,
          feature_flags: %{new_ui: false, beta_api: false},
          last_ip: "10.0.#{rem(i, 255)}.#{rem(i * 3, 255)}"
        },
        custom_attributes: %{
          department: "dept-#{rem(i, 50)}",
          cost_center: "CC-#{rem(i, 20)}",
          manager_id: "USR-#{max(1, i - 10)}"
        },
        created_at: DateTime.utc_now() |> DateTime.add(-365 * 86_400),
        updated_at: DateTime.utc_now() |> DateTime.add(-inactive_days * 86_400),
        gdpr_consents: %{marketing: false, analytics: true, essential: true}
      }
    end)
  end
end

defmodule UserManagement.ArchivalWorker do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{archived: 0}, opts)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:archive_users, users}, state) do
    # Simulate writing to cold storage
    count = length(users)
    {:noreply, %{state | archived: state.archived + count}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state, state}
  end
end

defmodule UserManagement.ArchivalJob do
  @moduledoc "Scheduled job that archives inactive users to cold storage."

  require Logger

  @inactive_threshold_days 180

  @spec enqueue(pid()) :: :ok
  def enqueue(worker_pid) do
    Logger.info("Fetching inactive users (>#{@inactive_threshold_days} days)")

    users = UserManagement.UserRepo.all_inactive(@inactive_threshold_days)

    Logger.info("Found #{length(users)} inactive users — forwarding to archival worker")

    send(worker_pid, {:archive_users, users})

    :ok
  end
end
```
