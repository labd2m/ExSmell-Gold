```elixir
defmodule Permissions.Tree do
  @moduledoc """
  Evaluates hierarchical permission strings with wildcard matching.

  Permissions are colon-delimited strings such as `"articles:comments:delete"`.
  A wildcard segment `*` matches any single segment at that position, and
  a trailing `**` grants all permissions under that namespace. Evaluating
  whether a principal holds a required permission traverses from most-specific
  to most-general match, enabling compact grants like `"articles:*"` to cover
  `"articles:read"`, `"articles:write"`, and `"articles:delete"` at once.
  """

  @type permission :: String.t()
  @type grant_set :: MapSet.t()

  @spec new([permission()]) :: grant_set()
  def new(permissions) when is_list(permissions) do
    MapSet.new(permissions)
  end

  @spec grant(grant_set(), permission()) :: grant_set()
  def grant(%MapSet{} = grants, permission) when is_binary(permission) do
    MapSet.put(grants, permission)
  end

  @spec revoke(grant_set(), permission()) :: grant_set()
  def revoke(%MapSet{} = grants, permission) when is_binary(permission) do
    MapSet.delete(grants, permission)
  end

  @spec permitted?(grant_set(), permission()) :: boolean()
  def permitted?(%MapSet{} = grants, required) when is_binary(required) do
    parts = String.split(required, ":")
    candidates = build_candidates(parts)
    Enum.any?(candidates, &MapSet.member?(grants, &1))
  end

  @spec permitted_all?(grant_set(), [permission()]) :: boolean()
  def permitted_all?(%MapSet{} = grants, required_list) when is_list(required_list) do
    Enum.all?(required_list, &permitted?(grants, &1))
  end

  @spec permitted_any?(grant_set(), [permission()]) :: boolean()
  def permitted_any?(%MapSet{} = grants, required_list) when is_list(required_list) do
    Enum.any?(required_list, &permitted?(grants, &1))
  end

  @spec matching_grants(grant_set(), String.t()) :: [permission()]
  def matching_grants(%MapSet{} = grants, namespace) when is_binary(namespace) do
    prefix = namespace <> ":"

    grants
    |> Enum.filter(fn grant ->
      grant == namespace or
        String.starts_with?(grant, prefix) or
        grant == namespace <> ":*" or
        grant == "**"
    end)
    |> Enum.sort()
  end

  @spec effective_namespaces(grant_set()) :: [String.t()]
  def effective_namespaces(%MapSet{} = grants) do
    grants
    |> Enum.flat_map(fn grant ->
      grant
      |> String.split(":")
      |> Enum.scan([], fn segment, acc -> acc ++ [segment] end)
      |> Enum.map(&Enum.join(&1, ":"))
    end)
    |> Enum.reject(&String.ends_with?(&1, "*"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp build_candidates(parts) do
    exact = Enum.join(parts, ":")
    wildcards = build_wildcards(parts, length(parts))
    [exact, "**" | wildcards]
  end

  defp build_wildcards(parts, len) do
    for i <- 0..(len - 1) do
      prefix = Enum.take(parts, i)

      [
        Enum.join(prefix ++ ["*"], ":"),
        Enum.join(prefix ++ ["**"], ":")
      ]
    end
    |> List.flatten()
    |> Enum.uniq()
  end
end

defmodule Permissions.Role do
  @moduledoc """
  Associates a named role with a set of permission grants.
  """

  alias Permissions.Tree

  @type t :: %__MODULE__{
          name: atom(),
          grants: Tree.grant_set(),
          inherits: [atom()]
        }

  defstruct [:name, :inherits, grants: MapSet.new()]

  @spec new(atom(), [Tree.permission()], [atom()]) :: t()
  def new(name, permissions, inherits \\ []) when is_atom(name) do
    %__MODULE__{name: name, grants: Tree.new(permissions), inherits: inherits}
  end

  @spec effective_grants(t(), %{atom() => t()}) :: Tree.grant_set()
  def effective_grants(%__MODULE__{} = role, all_roles) do
    parent_grants =
      role.inherits
      |> Enum.flat_map(fn parent_name ->
        case Map.fetch(all_roles, parent_name) do
          {:ok, parent} -> MapSet.to_list(effective_grants(parent, all_roles))
          :error -> []
        end
      end)
      |> MapSet.new()

    MapSet.union(role.grants, parent_grants)
  end
end
```
