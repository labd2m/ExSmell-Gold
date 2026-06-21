```elixir
defmodule Authorization.Policy do
  @moduledoc """
  Behaviour for resource-specific authorization policies.

  Each policy module covers a single resource type and declares which
  actions its `can?/3` callback permits. Policies receive the acting
  principal and the target resource; returning `true` grants access.
  """

  @callback can?(principal :: map(), action :: atom(), resource :: term()) :: boolean()
end

defmodule Authorization do
  @moduledoc """
  Entry point for evaluating authorization decisions.

  Policies are resolved by resource type; the registry maps each resource
  module to its governing policy module. Unregistered resource types fail
  closed, denying access rather than defaulting to permissive.
  """

  @policy_registry %{
    Accounts.User => Authorization.Policies.UserPolicy,
    Commerce.Cart => Authorization.Policies.CartPolicy,
    Catalog.Product => Authorization.Policies.ProductPolicy
  }

  @spec authorize(map(), atom(), term()) :: :ok | {:error, :unauthorized}
  def authorize(principal, action, resource) do
    case resolve_policy(resource) do
      {:ok, policy} ->
        if policy.can?(principal, action, resource) do
          :ok
        else
          {:error, :unauthorized}
        end

      {:error, :no_policy} ->
        {:error, :unauthorized}
    end
  end

  @spec authorize!(map(), atom(), term()) :: :ok
  def authorize!(principal, action, resource) do
    case authorize(principal, action, resource) do
      :ok -> :ok
      {:error, :unauthorized} -> raise Authorization.UnauthorizedError, action: action
    end
  end

  defp resolve_policy(%module{}) do
    case Map.fetch(@policy_registry, module) do
      {:ok, policy} -> {:ok, policy}
      :error -> {:error, :no_policy}
    end
  end
end

defmodule Authorization.Policies.UserPolicy do
  @moduledoc """
  Authorization rules for `Accounts.User` resources.
  """

  @behaviour Authorization.Policy

  @impl Authorization.Policy
  def can?(%{role: :admin}, _action, _user), do: true

  def can?(%{id: actor_id}, :read, %Accounts.User{id: target_id}) do
    actor_id == target_id
  end

  def can?(%{id: actor_id}, action, %Accounts.User{id: target_id})
      when action in [:update, :deactivate] do
    actor_id == target_id
  end

  def can?(_principal, _action, _user), do: false
end

defmodule Authorization.Policies.ProductPolicy do
  @moduledoc """
  Authorization rules for `Catalog.Product` resources.
  """

  @behaviour Authorization.Policy

  @impl Authorization.Policy
  def can?(%{role: :admin}, _action, _product), do: true
  def can?(_principal, :read, _product), do: true
  def can?(_principal, _action, _product), do: false
end

defmodule Authorization.Policies.CartPolicy do
  @moduledoc """
  Authorization rules for `Commerce.Cart` resources.
  """

  @behaviour Authorization.Policy

  @impl Authorization.Policy
  def can?(%{role: :admin}, _action, _cart), do: true

  def can?(%{id: actor_id}, _action, %Commerce.Cart{customer_id: owner_id}) do
    actor_id == owner_id
  end

  def can?(_principal, _action, _cart), do: false
end

defmodule Authorization.UnauthorizedError do
  defexception [:action]

  @impl Exception
  def message(%{action: action}), do: "Not authorized to perform #{action}"
end
```
