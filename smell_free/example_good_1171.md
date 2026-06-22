**File:** `example_good_1171.md`

```elixir
defmodule AccessControl.Principal do
  @moduledoc "Represents an authenticated principal with their granted roles."

  @enforce_keys [:id, :type, :roles]
  defstruct [:id, :type, :roles, :context]

  @type principal_type :: :user | :service_account | :api_key
  @type t :: %__MODULE__{
          id: String.t(),
          type: principal_type(),
          roles: [String.t()],
          context: map() | nil
        }
end

defmodule AccessControl.Permission do
  @moduledoc "Defines a discrete permission as a resource-action pair."

  @enforce_keys [:resource, :action]
  defstruct [:resource, :action, :conditions]

  @type t :: %__MODULE__{
          resource: String.t(),
          action: String.t(),
          conditions: map() | nil
        }

  @spec new(String.t(), String.t()) :: t()
  def new(resource, action) when is_binary(resource) and is_binary(action) do
    %__MODULE__{resource: resource, action: action, conditions: nil}
  end
end

defmodule AccessControl.Policy do
  @moduledoc """
  Defines the role-to-permissions mapping used for authorization decisions.
  Policies are immutable maps loaded at application startup.
  """

  alias AccessControl.Permission

  @type permission_set :: [Permission.t()]
  @type t :: %{String.t() => permission_set()}

  @spec build([{String.t(), [{String.t(), String.t()}]}]) :: t()
  def build(role_definitions) when is_list(role_definitions) do
    Map.new(role_definitions, fn {role, permission_pairs} ->
      permissions = Enum.map(permission_pairs, fn {resource, action} ->
        Permission.new(resource, action)
      end)

      {role, permissions}
    end)
  end

  @spec permissions_for_role(t(), String.t()) :: [Permission.t()]
  def permissions_for_role(policy, role) when is_map(policy) and is_binary(role) do
    Map.get(policy, role, [])
  end
end

defmodule AccessControl.Authorizer do
  @moduledoc """
  Evaluates whether a principal holds a given permission based on
  their roles and a loaded access control policy.
  """

  alias AccessControl.{Permission, Policy, Principal}

  @type decision :: :allow | :deny
  @type check_result :: {:ok, :allow} | {:error, :forbidden}

  @spec check(Principal.t(), Permission.t(), Policy.t()) :: check_result()
  def check(%Principal{} = principal, %Permission{} = permission, policy) do
    if authorized?(principal, permission, policy) do
      {:ok, :allow}
    else
      {:error, :forbidden}
    end
  end

  @spec authorized?(Principal.t(), Permission.t(), Policy.t()) :: boolean()
  def authorized?(%Principal{roles: roles}, %Permission{} = permission, policy) do
    Enum.any?(roles, fn role ->
      role
      |> Policy.permissions_for_role(policy)
      |> Enum.any?(&matches_permission?(&1, permission))
    end)
  end

  defp matches_permission?(
         %Permission{resource: res, action: act},
         %Permission{resource: target_res, action: target_act}
       ) do
    resource_matches?(res, target_res) and action_matches?(act, target_act)
  end

  defp resource_matches?("*", _target), do: true
  defp resource_matches?(res, target), do: res == target

  defp action_matches?("*", _target), do: true
  defp action_matches?(act, target), do: act == target
end

defmodule AccessControl do
  @moduledoc """
  Public interface for performing authorization checks in application code.
  """

  alias AccessControl.{Authorizer, Permission, Principal, Policy}

  @spec permit?(Principal.t(), String.t(), String.t(), Policy.t()) :: boolean()
  def permit?(%Principal{} = principal, resource, action, policy) do
    permission = Permission.new(resource, action)
    Authorizer.authorized?(principal, permission, policy)
  end

  @spec enforce!(Principal.t(), String.t(), String.t(), Policy.t()) :: :ok
  def enforce!(%Principal{} = principal, resource, action, policy) do
    permission = Permission.new(resource, action)

    case Authorizer.check(principal, permission, policy) do
      {:ok, :allow} -> :ok
      {:error, :forbidden} -> raise AccessControl.ForbiddenError, {resource, action}
    end
  end
end

defmodule AccessControl.ForbiddenError do
  @moduledoc "Raised when a principal is denied access to a resource-action pair."

  defexception [:resource, :action]

  @impl Exception
  def exception({resource, action}), do: %__MODULE__{resource: resource, action: action}

  @impl Exception
  def message(%__MODULE__{resource: r, action: a}), do: "Forbidden: #{a} on #{r}"
end
```
