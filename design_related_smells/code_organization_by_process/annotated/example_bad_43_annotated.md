# Annotated Example — Code Smell: Code Organization by Process

| Field | Value |
|---|---|
| **Smell name** | Code organization by process |
| **Expected smell location** | `PermissionChecker` module — entire GenServer structure |
| **Affected function(s)** | `has_permission?/3`, `allowed_actions/2`, `check_all/3`, `role_permissions/2` |
| **Short explanation** | Checking permissions is a pure lookup: given a user role and an action, it queries a static rule table and returns a boolean. No state is mutated, no I/O is performed, and no resource is shared between calls. Wrapping this in a GenServer serialises all authorization checks in the system without providing any concurrency benefit. |

```elixir
defmodule Auth.PermissionChecker do
  use GenServer

  @moduledoc """
  Evaluates whether a user role is allowed to perform a given action on
  a resource type. Used by the API controller layer for authorization checks.
  """

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because permission checking is a pure lookup
  # against a static access-control matrix. The GenServer holds no dynamic
  # state — it is always %{}. Every HTTP request that reaches an authorized
  # endpoint must go through this single process, serialising checks that
  # could trivially run in parallel within each request process.

  @permissions %{
    superadmin: %{
      orders:    [:read, :create, :update, :delete, :export],
      users:     [:read, :create, :update, :delete, :impersonate],
      products:  [:read, :create, :update, :delete],
      reports:   [:read, :create, :export],
      settings:  [:read, :update]
    },
    admin: %{
      orders:    [:read, :create, :update, :delete, :export],
      users:     [:read, :create, :update],
      products:  [:read, :create, :update],
      reports:   [:read, :create, :export],
      settings:  [:read]
    },
    manager: %{
      orders:    [:read, :create, :update, :export],
      users:     [:read],
      products:  [:read, :update],
      reports:   [:read, :export],
      settings:  []
    },
    support: %{
      orders:    [:read, :update],
      users:     [:read],
      products:  [:read],
      reports:   [:read],
      settings:  []
    },
    viewer: %{
      orders:    [:read],
      users:     [],
      products:  [:read],
      reports:   [:read],
      settings:  []
    }
  }

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc "Returns `true` if `role` is permitted to perform `action` on `resource`."
  def has_permission?(pid, role, resource, action) do
    GenServer.call(pid, {:has_permission?, role, resource, action})
  end

  @doc "Returns the list of allowed actions for `role` on `resource`."
  def allowed_actions(pid, role, resource) do
    GenServer.call(pid, {:allowed_actions, role, resource})
  end

  @doc """
  Checks multiple `{resource, action}` tuples for `role`. Returns
  `{:ok, results_map}` mapping each pair to `true | false`.
  """
  def check_all(pid, role, checks) do
    GenServer.call(pid, {:check_all, role, checks})
  end

  @doc "Returns the full permissions map for `role`."
  def role_permissions(pid, role) do
    GenServer.call(pid, {:role_permissions, role})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:has_permission?, role, resource, action}, _from, state) do
    allowed =
      case get_in(@permissions, [role, resource]) do
        nil     -> false
        actions -> action in actions
      end

    {:reply, allowed, state}
  end

  def handle_call({:allowed_actions, role, resource}, _from, state) do
    actions =
      case get_in(@permissions, [role, resource]) do
        nil     -> []
        actions -> actions
      end

    {:reply, {:ok, actions}, state}
  end

  def handle_call({:check_all, role, checks}, _from, state) do
    results =
      Enum.into(checks, %{}, fn {resource, action} ->
        allowed =
          case get_in(@permissions, [role, resource]) do
            nil     -> false
            actions -> action in actions
          end

        {{resource, action}, allowed}
      end)

    {:reply, {:ok, results}, state}
  end

  def handle_call({:role_permissions, role}, _from, state) do
    result =
      case Map.get(@permissions, role) do
        nil  -> {:error, :unknown_role}
        perms -> {:ok, perms}
      end

    {:reply, result, state}
  end

  # VALIDATION: SMELL END
end
```
