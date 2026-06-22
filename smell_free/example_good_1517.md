```elixir
defmodule Access.RolePolicy do
  @moduledoc """
  Defines and evaluates role-based access control policies for
  application resources.

  Policies are evaluated as pure functions against a principal struct
  and a resource descriptor. No global state or process interaction
  is required.
  """

  alias Access.Principal
  alias Access.ResourceDescriptor

  @type action :: :read | :write | :delete | :admin
  @type policy_result :: :allow | {:deny, String.t()}

  @doc """
  Evaluates whether a principal is permitted to perform the given
  action on the described resource.

  Returns `:allow` or `{:deny, reason}`.
  """
  @spec evaluate(Principal.t(), action(), ResourceDescriptor.t()) :: policy_result()
  def evaluate(%Principal{role: :super_admin}, _action, _resource), do: :allow

  def evaluate(%Principal{role: :admin}, action, %ResourceDescriptor{scope: :organization})
      when action in [:read, :write, :delete] do
    :allow
  end

  def evaluate(%Principal{role: :admin}, :admin, _resource) do
    {:deny, "Admin role does not have admin-level access to this resource."}
  end

  def evaluate(%Principal{role: :member} = principal, :read, resource) do
    if principal.organization_id == resource.organization_id do
      :allow
    else
      {:deny, "Members may only read resources within their own organization."}
    end
  end

  def evaluate(%Principal{role: :member} = principal, action, resource)
      when action in [:write, :delete] do
    if principal.organization_id == resource.organization_id and
         resource.owner_id == principal.id do
      :allow
    else
      {:deny, "Members may only modify resources they own within their organization."}
    end
  end

  def evaluate(%Principal{role: :member}, :admin, _resource) do
    {:deny, "Members are not permitted to perform administrative actions."}
  end

  def evaluate(%Principal{role: :guest}, :read, %ResourceDescriptor{visibility: :public}) do
    :allow
  end

  def evaluate(%Principal{role: :guest}, _action, _resource) do
    {:deny, "Guests may only read publicly visible resources."}
  end

  def evaluate(_principal, _action, _resource) do
    {:deny, "Access denied: unrecognized principal role or resource configuration."}
  end

  @doc """
  Returns `true` if the principal is allowed to perform the action,
  `false` otherwise.
  """
  @spec permitted?(Principal.t(), action(), ResourceDescriptor.t()) :: boolean()
  def permitted?(principal, action, resource) do
    evaluate(principal, action, resource) == :allow
  end

  @doc """
  Asserts that a principal may perform an action, raising on denial.
  """
  @spec authorize!(Principal.t(), action(), ResourceDescriptor.t()) ::
          :ok | no_return()
  def authorize!(principal, action, resource) do
    case evaluate(principal, action, resource) do
      :allow -> :ok
      {:deny, reason} -> raise Access.AuthorizationError, message: reason
    end
  end
end
```
