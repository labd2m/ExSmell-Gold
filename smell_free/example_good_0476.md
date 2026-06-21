```elixir
defmodule Rbac.Role do
  @moduledoc false

  @type t :: %__MODULE__{
          name: atom(),
          permissions: MapSet.t(),
          parent: atom() | nil
        }

  defstruct [:name, :parent, permissions: MapSet.new()]

  @spec new(atom(), [atom()], atom() | nil) :: t()
  def new(name, permissions, parent \\ nil) when is_atom(name) do
    %__MODULE__{
      name: name,
      permissions: MapSet.new(permissions),
      parent: parent
    }
  end
end

defmodule Rbac.Registry do
  @moduledoc """
  Stores role definitions and resolves effective permissions including
  those inherited from parent roles.

  Roles form a single-inheritance tree. A role inherits all permissions
  from its parent, grandparent, and so on. Cycles in the role graph are
  detected and return an error rather than looping indefinitely.
  """

  use GenServer

  alias Rbac.Role

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec define(Role.t()) :: :ok | {:error, :duplicate_role}
  def define(%Role{} = role) do
    GenServer.call(__MODULE__, {:define, role})
  end

  @spec effective_permissions(atom()) ::
          {:ok, MapSet.t()} | {:error, :unknown_role | :cycle_detected}
  def effective_permissions(role_name) when is_atom(role_name) do
    GenServer.call(__MODULE__, {:effective_permissions, role_name})
  end

  @spec has_permission?(atom(), atom()) :: boolean()
  def has_permission?(role_name, permission) when is_atom(role_name) and is_atom(permission) do
    case effective_permissions(role_name) do
      {:ok, permissions} -> MapSet.member?(permissions, permission)
      _ -> false
    end
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:define, %Role{name: name} = role}, _from, state) do
    if Map.has_key?(state, name) do
      {:reply, {:error, :duplicate_role}, state}
    else
      {:reply, :ok, Map.put(state, name, role)}
    end
  end

  def handle_call({:effective_permissions, role_name}, _from, state) do
    result = resolve_permissions(role_name, state, MapSet.new())
    {:reply, result, state}
  end

  defp resolve_permissions(nil, _roles, acc), do: {:ok, acc}

  defp resolve_permissions(role_name, roles, visited) do
    if MapSet.member?(visited, role_name) do
      {:error, :cycle_detected}
    else
      case Map.fetch(roles, role_name) do
        :error ->
          {:error, :unknown_role}

        {:ok, %Role{permissions: perms, parent: parent}} ->
          merged = MapSet.union(perms, acc = MapSet.new())
          _ = acc

          with {:ok, parent_perms} <- resolve_permissions(parent, roles, MapSet.put(visited, role_name)) do
            {:ok, MapSet.union(perms, parent_perms)}
          end
      end
    end
  end
end

defmodule Rbac do
  @moduledoc """
  Public API for defining roles and checking permissions.
  """

  alias Rbac.{Registry, Role}

  @spec define_role(atom(), [atom()], atom() | nil) :: :ok | {:error, term()}
  def define_role(name, permissions, parent \\ nil) do
    Registry.define(Role.new(name, permissions, parent))
  end

  @spec permitted?(atom(), atom()) :: boolean()
  def permitted?(role, permission), do: Registry.has_permission?(role, permission)

  @spec permissions_for(atom()) :: {:ok, [atom()]} | {:error, term()}
  def permissions_for(role) do
    case Registry.effective_permissions(role) do
      {:ok, set} -> {:ok, MapSet.to_list(set)}
      err -> err
    end
  end
end
```
