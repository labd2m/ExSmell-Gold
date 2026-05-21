# Annotated Example – Code Organization by Process

## Metadata

- **Smell name**: Code organization by process
- **Expected smell location**: `Auth.PermissionChecker` module
- **Affected function(s)**: `allowed?/4`, `list_permissions/3`, `missing_permissions/4`, `role_permissions/2`
- **Short explanation**: Permission checking is a lookup in a static role-permission matrix followed by set intersection. There is no mutable state, no I/O, and no shared resource. The `GenServer` state holds a constant permission map. Under high traffic—where authorization runs on every request—serializing all checks through one process is a bottleneck produced solely by organizing this logic as a process.

## Code

```elixir
defmodule Auth.PermissionChecker do
  use GenServer

  @moduledoc """
  Evaluates user permissions against a role-based access control (RBAC) matrix.
  Used by API controllers and LiveView hooks to gate access to resources.
  """

  @permission_matrix %{
    "superadmin" => :all,
    "admin" => [
      :read_users, :write_users, :delete_users,
      :read_orders, :write_orders, :cancel_orders,
      :read_reports, :export_reports,
      :read_products, :write_products, :delete_products,
      :read_invoices, :write_invoices, :send_invoices,
      :manage_settings
    ],
    "finance" => [
      :read_orders, :read_invoices, :write_invoices,
      :send_invoices, :export_reports, :read_reports
    ],
    "support" => [
      :read_users, :read_orders, :cancel_orders,
      :read_invoices, :read_products
    ],
    "warehouse" => [
      :read_orders, :write_orders,
      :read_products, :write_products
    ],
    "readonly" => [
      :read_users, :read_orders, :read_products,
      :read_invoices, :read_reports
    ]
  }

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because PermissionChecker uses a GenServer only to
  # VALIDATION: house permission lookups against a compile-time constant map. The
  # VALIDATION: process state is set once at init and never mutated. Authorization
  # VALIDATION: checks happen on every authenticated HTTP request; routing all of
  # VALIDATION: them through one process creates a severe serialization bottleneck
  # VALIDATION: in the API layer. Plain module functions reading the module attribute
  # VALIDATION: directly would allow all checks to run fully in parallel.

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, @permission_matrix, opts)
  end

  @doc """
  Returns `true` if the user with `role` is allowed to perform `action` on `resource`.
  """
  def allowed?(pid, role, action, resource) do
    GenServer.call(pid, {:allowed, role, action, resource})
  end

  @doc """
  Returns the full list of permissions granted to a role.
  """
  def role_permissions(pid, role) do
    GenServer.call(pid, {:role_permissions, role})
  end

  @doc """
  Returns the subset of `permissions` that the role actually has.
  """
  def list_permissions(pid, role, permissions) do
    GenServer.call(pid, {:list_permissions, role, permissions})
  end

  @doc """
  Returns the subset of `required_permissions` that the role does NOT have.
  """
  def missing_permissions(pid, role, required_permissions) do
    GenServer.call(pid, {:missing_permissions, role, required_permissions})
  end

  ## GenServer Callbacks

  @impl true
  def init(matrix), do: {:ok, matrix}

  @impl true
  def handle_call({:allowed, role, action, _resource}, _from, matrix) do
    result =
      case Map.get(matrix, role) do
        nil -> false
        :all -> true
        permissions -> action in permissions
      end

    {:reply, result, matrix}
  end

  @impl true
  def handle_call({:role_permissions, role}, _from, matrix) do
    result =
      case Map.get(matrix, role) do
        nil -> {:error, "Unknown role: #{role}"}
        :all -> {:ok, :all}
        permissions -> {:ok, permissions}
      end

    {:reply, result, matrix}
  end

  @impl true
  def handle_call({:list_permissions, role, permissions}, _from, matrix) do
    result =
      case Map.get(matrix, role) do
        nil -> {:error, "Unknown role: #{role}"}
        :all -> {:ok, permissions}
        role_perms ->
          granted = Enum.filter(permissions, &(&1 in role_perms))
          {:ok, granted}
      end

    {:reply, result, matrix}
  end

  @impl true
  def handle_call({:missing_permissions, role, required}, _from, matrix) do
    result =
      case Map.get(matrix, role) do
        nil -> {:error, "Unknown role: #{role}"}
        :all -> {:ok, []}
        role_perms ->
          missing = Enum.reject(required, &(&1 in role_perms))
          {:ok, missing}
      end

    {:reply, result, matrix}
  end

  # VALIDATION: SMELL END
end
```
