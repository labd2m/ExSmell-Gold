**File:** `example_good_1409.md`

```elixir
defmodule RoleHierarchy.Role do
  @moduledoc "Represents a single role with its directly assigned permissions."

  @enforce_keys [:name, :permissions]
  defstruct [:name, :permissions, :inherits_from]

  @type t :: %__MODULE__{
          name: atom(),
          permissions: MapSet.t(atom()),
          inherits_from: [atom()]
        }

  @spec new(atom(), [atom()], keyword()) :: t()
  def new(name, permissions, opts \\ []) when is_atom(name) and is_list(permissions) do
    %__MODULE__{
      name: name,
      permissions: MapSet.new(permissions),
      inherits_from: Keyword.get(opts, :inherits_from, [])
    }
  end
end

defmodule RoleHierarchy.Graph do
  @moduledoc """
  Builds a directed role inheritance graph and resolves the full set of
  effective permissions for any role, including those inherited transitively.
  Detects cycles during graph construction.
  """

  alias RoleHierarchy.Role

  @type t :: %{atom() => Role.t()}

  @spec build([Role.t()]) :: {:ok, t()} | {:error, {:cyclic_inheritance, atom()}}
  def build(roles) when is_list(roles) do
    graph = Map.new(roles, fn r -> {r.name, r} end)

    case detect_cycle(graph) do
      nil -> {:ok, graph}
      cycle_root -> {:error, {:cyclic_inheritance, cycle_root}}
    end
  end

  @spec effective_permissions(t(), atom()) :: {:ok, MapSet.t(atom())} | {:error, :unknown_role}
  def effective_permissions(graph, role_name) when is_atom(role_name) do
    case Map.fetch(graph, role_name) do
      {:ok, _} -> {:ok, collect_permissions(graph, role_name, MapSet.new())}
      :error -> {:error, :unknown_role}
    end
  end

  @spec has_permission?(t(), atom(), atom()) :: boolean() | {:error, :unknown_role}
  def has_permission?(graph, role_name, permission) do
    case effective_permissions(graph, role_name) do
      {:ok, perms} -> MapSet.member?(perms, permission)
      {:error, _} = err -> err
    end
  end

  @spec ancestors(t(), atom()) :: [atom()]
  def ancestors(graph, role_name) when is_atom(role_name) do
    collect_ancestors(graph, role_name, [])
  end

  defp collect_permissions(graph, role_name, visited_roles) do
    if MapSet.member?(visited_roles, role_name) do
      MapSet.new()
    else
      case Map.get(graph, role_name) do
        nil ->
          MapSet.new()

        %Role{permissions: direct, inherits_from: parents} ->
          new_visited = MapSet.put(visited_roles, role_name)

          inherited =
            Enum.reduce(parents, MapSet.new(), fn parent, acc ->
              MapSet.union(acc, collect_permissions(graph, parent, new_visited))
            end)

          MapSet.union(direct, inherited)
      end
    end
  end

  defp collect_ancestors(graph, role_name, seen) do
    case Map.get(graph, role_name) do
      nil ->
        seen

      %Role{inherits_from: []} ->
        seen

      %Role{inherits_from: parents} ->
        Enum.reduce(parents, seen, fn parent, acc ->
          if parent in acc do
            acc
          else
            collect_ancestors(graph, parent, [parent | acc])
          end
        end)
    end
  end

  defp detect_cycle(graph) do
    Enum.find_value(graph, fn {name, _} ->
      if has_cycle?(graph, name, MapSet.new()), do: name, else: nil
    end)
  end

  defp has_cycle?(graph, role_name, visiting) do
    if MapSet.member?(visiting, role_name) do
      true
    else
      case Map.get(graph, role_name) do
        nil ->
          false

        %Role{inherits_from: parents} ->
          new_visiting = MapSet.put(visiting, role_name)
          Enum.any?(parents, &has_cycle?(graph, &1, new_visiting))
      end
    end
  end
end

defmodule RoleHierarchy do
  @moduledoc "Convenience interface for building and querying role hierarchies."

  alias RoleHierarchy.{Graph, Role}

  @spec define([{atom(), [atom()], keyword()}]) :: {:ok, Graph.t()} | {:error, term()}
  def define(role_specs) when is_list(role_specs) do
    roles = Enum.map(role_specs, fn {name, perms, opts} -> Role.new(name, perms, opts) end)
    Graph.build(roles)
  end

  @spec can?(Graph.t(), atom(), atom()) :: boolean()
  def can?(graph, role_name, permission) do
    case Graph.has_permission?(graph, role_name, permission) do
      result when is_boolean(result) -> result
      {:error, _} -> false
    end
  end
end
```
