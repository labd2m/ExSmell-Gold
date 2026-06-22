```elixir
defmodule Authz.PolicyEngine do
  @moduledoc """
  Evaluates access control policies for resource-action pairs.

  Policies are composed of role-based rules and optional attribute conditions.
  Evaluation is purely functional: no I/O is performed during permission checks.
  """

  alias Authz.PolicyEngine.{Policy, Rule, Principal, Decision}

  @doc """
  Evaluates whether a principal may perform an action on a resource.

  Returns a `Decision` struct with the outcome and the matching rule, if any.
  """
  @spec evaluate(Principal.t(), String.t(), map(), [Policy.t()]) :: Decision.t()
  def evaluate(%Principal{} = principal, action, resource, policies)
      when is_binary(action) and is_map(resource) and is_list(policies) do
    applicable_rules =
      policies
      |> Enum.filter(&Policy.applies_to_principal?(&1, principal))
      |> Enum.flat_map(& &1.rules)
      |> Enum.filter(&Rule.matches_action?(&1, action))

    resolve(applicable_rules, principal, resource, action)
  end

  defp resolve([], _principal, _resource, action) do
    Decision.deny(action, :no_matching_rule)
  end

  defp resolve(rules, principal, resource, action) do
    deny_rule = Enum.find(rules, &(&1.effect == :deny and Rule.conditions_met?(&1, principal, resource)))

    if deny_rule do
      Decision.deny(action, {:explicit_deny, deny_rule.id})
    else
      allow_rule = Enum.find(rules, &(&1.effect == :allow and Rule.conditions_met?(&1, principal, resource)))
      if allow_rule, do: Decision.allow(action, allow_rule.id), else: Decision.deny(action, :no_allow_rule)
    end
  end
end

defmodule Authz.PolicyEngine.Principal do
  @moduledoc "Represents an actor being evaluated for access."

  @enforce_keys [:id, :roles]
  defstruct [:id, :roles, attributes: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          roles: [String.t()],
          attributes: map()
        }

  @spec new(String.t(), [String.t()], map()) :: t()
  def new(id, roles, attributes \\ %{})
      when is_binary(id) and is_list(roles) and is_map(attributes) do
    %__MODULE__{id: id, roles: roles, attributes: attributes}
  end
end

defmodule Authz.PolicyEngine.Rule do
  @moduledoc "A single access control rule within a policy."

  @enforce_keys [:id, :actions, :effect]
  defstruct [:id, :actions, :effect, conditions: []]

  @type effect :: :allow | :deny
  @type t :: %__MODULE__{
          id: String.t(),
          actions: [String.t()] | :all,
          effect: effect(),
          conditions: [map()]
        }

  @spec matches_action?(t(), String.t()) :: boolean()
  def matches_action?(%__MODULE__{actions: :all}, _action), do: true
  def matches_action?(%__MODULE__{actions: actions}, action), do: action in actions

  @spec conditions_met?(t(), Authz.PolicyEngine.Principal.t(), map()) :: boolean()
  def conditions_met?(%__MODULE__{conditions: []}, _principal, _resource), do: true

  def conditions_met?(%__MODULE__{conditions: conditions}, principal, resource) do
    Enum.all?(conditions, &evaluate_condition(&1, principal, resource))
  end

  defp evaluate_condition(%{type: :resource_attribute, key: key, value: expected}, _p, resource) do
    Map.get(resource, key) == expected
  end

  defp evaluate_condition(%{type: :principal_attribute, key: key, value: expected}, principal, _r) do
    Map.get(principal.attributes, key) == expected
  end

  defp evaluate_condition(_, _, _), do: false
end

defmodule Authz.PolicyEngine.Policy do
  @moduledoc "A named collection of access rules scoped to specific roles."

  @enforce_keys [:id, :roles, :rules]
  defstruct [:id, :roles, :rules]

  @type t :: %__MODULE__{
          id: String.t(),
          roles: [String.t()] | :all,
          rules: [Authz.PolicyEngine.Rule.t()]
        }

  @spec applies_to_principal?(t(), Authz.PolicyEngine.Principal.t()) :: boolean()
  def applies_to_principal?(%__MODULE__{roles: :all}, _principal), do: true

  def applies_to_principal?(%__MODULE__{roles: policy_roles}, %{roles: principal_roles}) do
    Enum.any?(principal_roles, &(&1 in policy_roles))
  end
end

defmodule Authz.PolicyEngine.Decision do
  @moduledoc "Result of a policy evaluation."

  @enforce_keys [:action, :granted, :reason]
  defstruct [:action, :granted, :reason, :matched_rule_id]

  @type t :: %__MODULE__{
          action: String.t(),
          granted: boolean(),
          reason: atom() | tuple(),
          matched_rule_id: String.t() | nil
        }

  @spec allow(String.t(), String.t()) :: t()
  def allow(action, rule_id) do
    %__MODULE__{action: action, granted: true, reason: :allow, matched_rule_id: rule_id}
  end

  @spec deny(String.t(), atom() | tuple()) :: t()
  def deny(action, reason) do
    %__MODULE__{action: action, granted: false, reason: reason}
  end
end
```
