```elixir
defmodule Access.PolicyEngine do
  @moduledoc """
  Evaluates attribute-based access control (ABAC) policies. Each policy
  is a named rule composed of subject, resource, and environment conditions.
  All conditions are pure predicate functions stored in a map so policies
  are data-driven and easily tested. The engine returns a structured
  decision with the matching policy name for audit purposes.
  """

  @type subject :: map()
  @type resource :: map()
  @type environment :: map()
  @type condition_fn :: (subject(), resource(), environment() -> boolean())

  @type policy :: %{
          name: String.t(),
          effect: :allow | :deny,
          conditions: [condition_fn()]
        }

  @type decision :: %{
          effect: :allow | :deny,
          policy: String.t() | nil,
          reason: :explicit_allow | :explicit_deny | :default_deny
        }

  @doc """
  Evaluates `policies` in order against the given subject, resource, and
  environment. The first matching policy wins. Returns a deny decision with
  `policy: nil` when no policy matches.
  """
  @spec evaluate([policy()], subject(), resource(), environment()) :: decision()
  def evaluate(policies, subject, resource, environment)
      when is_list(policies) and is_map(subject) and is_map(resource) and is_map(environment) do
    Enum.find_value(policies, default_deny(), fn policy ->
      if all_conditions_pass?(policy.conditions, subject, resource, environment) do
        build_decision(policy)
      end
    end)
  end

  @doc """
  Returns true when `subject` is allowed to perform `action` on `resource`
  according to the evaluated decision.
  """
  @spec allowed?([policy()], subject(), resource(), environment()) :: boolean()
  def allowed?(policies, subject, resource, environment) do
    %{effect: effect} = evaluate(policies, subject, resource, environment)
    effect == :allow
  end

  @doc "Builds a deny-all policy that matches every request."
  @spec deny_all(String.t()) :: policy()
  def deny_all(name \ "deny_all") do
    %{name: name, effect: :deny, conditions: [fn _s, _r, _e -> true end]}
  end

  @doc "Builds an allow-all policy that matches every request."
  @spec allow_all(String.t()) :: policy()
  def allow_all(name \ "allow_all") do
    %{name: name, effect: :allow, conditions: [fn _s, _r, _e -> true end]}
  end

  @doc "Returns a condition function that checks a subject attribute equals a value."
  @spec subject_attr(atom(), term()) :: condition_fn()
  def subject_attr(key, expected) when is_atom(key) do
    fn subject, _resource, _env -> Map.get(subject, key) == expected end
  end

  @doc "Returns a condition that checks a resource attribute equals a value."
  @spec resource_attr(atom(), term()) :: condition_fn()
  def resource_attr(key, expected) when is_atom(key) do
    fn _subject, resource, _env -> Map.get(resource, key) == expected end
  end

  @doc "Returns a condition that checks a resource attribute is owned by the subject."
  @spec owns_resource(atom(), atom()) :: condition_fn()
  def owns_resource(resource_owner_key, subject_id_key) do
    fn subject, resource, _env ->
      Map.get(resource, resource_owner_key) == Map.get(subject, subject_id_key)
    end
  end

  defp all_conditions_pass?(conditions, subject, resource, environment) do
    Enum.all?(conditions, fn cond_fn -> cond_fn.(subject, resource, environment) end)
  end

  defp build_decision(%{effect: :allow, name: name}) do
    %{effect: :allow, policy: name, reason: :explicit_allow}
  end

  defp build_decision(%{effect: :deny, name: name}) do
    %{effect: :deny, policy: name, reason: :explicit_deny}
  end

  defp default_deny do
    %{effect: :deny, policy: nil, reason: :default_deny}
  end
end
```
