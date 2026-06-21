```elixir
defmodule MyApp.Accounts.PermissionSet do
  @moduledoc """
  Encodes and evaluates a set of fine-grained permissions for a user
  or API token as an immutable value object. Permissions are represented
  as a `MapSet` of `{resource_type, action}` tuples, allowing O(1)
  membership checks and clean composition via set operations.

  Permission sets can be constructed from role templates, from individual
  grants stored in the database, or by composing multiple sets together.
  """

  @enforce_keys [:grants]
  defstruct [:grants]

  @type resource :: atom()
  @type action :: atom()
  @type grant :: {resource(), action()}

  @type t :: %__MODULE__{
          grants: MapSet.t()
        }

  @role_templates %{
    admin: [
      {:orders, :read}, {:orders, :write}, {:orders, :delete},
      {:products, :read}, {:products, :write}, {:products, :delete},
      {:users, :read}, {:users, :write},
      {:reports, :read},
      {:settings, :read}, {:settings, :write}
    ],
    manager: [
      {:orders, :read}, {:orders, :write},
      {:products, :read}, {:products, :write},
      {:users, :read},
      {:reports, :read}
    ],
    viewer: [
      {:orders, :read},
      {:products, :read},
      {:reports, :read}
    ]
  }

  @doc "Builds a permission set from a named role template."
  @spec from_role(atom()) :: t() | {:error, :unknown_role}
  def from_role(role) when is_atom(role) do
    case Map.fetch(@role_templates, role) do
      {:ok, grants} -> new(grants)
      :error -> {:error, :unknown_role}
    end
  end

  @doc "Builds a permission set from a list of `{resource, action}` tuples."
  @spec new([grant()]) :: t()
  def new(grants) when is_list(grants) do
    %__MODULE__{grants: MapSet.new(grants)}
  end

  @doc "Returns `true` when the set permits `action` on `resource`."
  @spec permitted?(t(), resource(), action()) :: boolean()
  def permitted?(%__MODULE__{grants: grants}, resource, action) do
    MapSet.member?(grants, {resource, action})
  end

  @doc "Returns the list of all permitted grants."
  @spec to_list(t()) :: [grant()]
  def to_list(%__MODULE__{grants: grants}), do: MapSet.to_list(grants)

  @doc "Returns the count of granted permissions."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{grants: grants}), do: MapSet.size(grants)

  @doc "Returns a new set containing grants from both sets."
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{grants: a}, %__MODULE__{grants: b}) do
    %__MODULE__{grants: MapSet.union(a, b)}
  end

  @doc "Returns a new set containing only grants present in both sets."
  @spec intersect(t(), t()) :: t()
  def intersect(%__MODULE__{grants: a}, %__MODULE__{grants: b}) do
    %__MODULE__{grants: MapSet.intersection(a, b)}
  end

  @doc "Returns a new set with `grant` added."
  @spec add(t(), grant()) :: t()
  def add(%__MODULE__{grants: grants}, grant) do
    %__MODULE__{grants: MapSet.put(grants, grant)}
  end

  @doc "Returns a new set with `grant` removed."
  @spec revoke(t(), grant()) :: t()
  def revoke(%__MODULE__{grants: grants}, grant) do
    %__MODULE__{grants: MapSet.delete(grants, grant)}
  end

  @doc "Returns `true` when `set` grants every permission in `required`."
  @spec satisfies?(t(), t()) :: boolean()
  def satisfies?(%__MODULE__{grants: available}, %__MODULE__{grants: required}) do
    MapSet.subset?(required, available)
  end
end
```
