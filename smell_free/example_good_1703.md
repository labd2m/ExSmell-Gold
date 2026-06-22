```elixir
defmodule Access.PermissionMatrix do
  @moduledoc """
  Evaluates structured access permissions for authenticated subjects against
  resource-action pairs. Supports role inheritance and explicit denials.
  """

  @type subject :: %{id: String.t(), roles: [String.t()]}
  @type resource :: String.t()
  @type action :: String.t()
  @type rule :: %{role: String.t(), resource: resource(), action: action(), effect: :allow | :deny}
  @type policy :: [rule()]
  @type decision :: :allow | :deny

  @spec evaluate(subject(), resource(), action(), policy()) :: decision()
  def evaluate(%{roles: roles}, resource, action, policy)
      when is_binary(resource) and is_binary(action) and is_list(policy) do
    applicable = applicable_rules(roles, resource, action, policy)
    resolve_decision(applicable)
  end

  @spec can?(subject(), resource(), action(), policy()) :: boolean()
  def can?(subject, resource, action, policy) do
    evaluate(subject, resource, action, policy) == :allow
  end

  @spec grant_summary(subject(), policy()) :: %{resource() => [action()]}
  def grant_summary(%{roles: roles}, policy) do
    policy
    |> Enum.filter(&(&1.role in roles and &1.effect == :allow))
    |> Enum.reduce(%{}, fn rule, acc ->
      Map.update(acc, rule.resource, [rule.action], &[rule.action | &1])
    end)
    |> Map.new(fn {resource, actions} -> {resource, Enum.uniq(actions)} end)
  end

  @spec roles_with_access(resource(), action(), policy()) :: [String.t()]
  def roles_with_access(resource, action, policy)
      when is_binary(resource) and is_binary(action) do
    policy
    |> Enum.filter(&(&1.resource == resource and &1.action == action and &1.effect == :allow))
    |> Enum.map(& &1.role)
    |> Enum.uniq()
  end

  @spec applicable_rules([String.t()], resource(), action(), policy()) :: [rule()]
  defp applicable_rules(roles, resource, action, policy) do
    Enum.filter(policy, fn rule ->
      rule.role in roles and matches_resource?(rule.resource, resource) and
        matches_action?(rule.action, action)
    end)
  end

  @spec resolve_decision([rule()]) :: decision()
  defp resolve_decision([]), do: :deny

  defp resolve_decision(rules) do
    if Enum.any?(rules, &(&1.effect == :deny)) do
      :deny
    else
      :allow
    end
  end

  @spec matches_resource?(resource(), resource()) :: boolean()
  defp matches_resource?("*", _), do: true
  defp matches_resource?(pattern, resource), do: pattern == resource

  @spec matches_action?(action(), action()) :: boolean()
  defp matches_action?("*", _), do: true
  defp matches_action?(pattern, action), do: pattern == action
end

defmodule Access.PolicyBuilder do
  @moduledoc """
  Fluent builder for constructing structured `Access.PermissionMatrix` policies.
  """

  alias Access.PermissionMatrix

  @type t :: %__MODULE__{rules: PermissionMatrix.policy()}

  defstruct rules: []

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec allow(t(), String.t(), PermissionMatrix.resource(), PermissionMatrix.action()) :: t()
  def allow(%__MODULE__{} = builder, role, resource, action)
      when is_binary(role) and is_binary(resource) and is_binary(action) do
    rule = %{role: role, resource: resource, action: action, effect: :allow}
    %{builder | rules: [rule | builder.rules]}
  end

  @spec deny(t(), String.t(), PermissionMatrix.resource(), PermissionMatrix.action()) :: t()
  def deny(%__MODULE__{} = builder, role, resource, action)
      when is_binary(role) and is_binary(resource) and is_binary(action) do
    rule = %{role: role, resource: resource, action: action, effect: :deny}
    %{builder | rules: [rule | builder.rules]}
  end

  @spec build(t()) :: PermissionMatrix.policy()
  def build(%__MODULE__{rules: rules}), do: Enum.reverse(rules)
end
```
