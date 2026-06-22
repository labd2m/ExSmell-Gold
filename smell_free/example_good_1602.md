```elixir
defmodule Access.PolicyEvaluator do
  @moduledoc """
  Evaluates attribute-based access control policies against a subject,
  action, and resource triple. Policies are loaded from a store and
  evaluated in priority order, with explicit deny taking precedence.
  """

  alias Access.{PolicyStore, Policy}

  @type subject :: %{id: String.t(), roles: [String.t()], attributes: map()}
  @type action :: atom()
  @type resource :: %{type: String.t(), id: String.t(), attributes: map()}
  @type decision :: :allow | :deny | :not_applicable

  @type evaluation_result :: %{
          decision: decision(),
          matched_policy: String.t() | nil,
          reason: String.t()
        }

  @spec evaluate(subject(), action(), resource()) :: evaluation_result()
  def evaluate(subject, action, resource)
      when is_map(subject) and is_atom(action) and is_map(resource) do
    policies = PolicyStore.list_applicable(resource.type, action)

    case find_decisive_policy(policies, subject, action, resource) do
      {:deny, policy} ->
        %{decision: :deny, matched_policy: policy.name, reason: policy.deny_reason}

      {:allow, policy} ->
        %{decision: :allow, matched_policy: policy.name, reason: "Permitted by #{policy.name}"}

      :not_applicable ->
        %{decision: :deny, matched_policy: nil, reason: "No applicable policy found"}
    end
  end

  @spec can?(subject(), action(), resource()) :: boolean()
  def can?(subject, action, resource) do
    evaluate(subject, action, resource).decision == :allow
  end

  @spec find_decisive_policy([Policy.t()], subject(), action(), resource()) ::
          {:allow | :deny, Policy.t()} | :not_applicable
  defp find_decisive_policy(policies, subject, action, resource) do
    deny =
      Enum.find(policies, fn p ->
        p.effect == :deny and matches_conditions?(p, subject, action, resource)
      end)

    case deny do
      %Policy{} = p ->
        {:deny, p}

      nil ->
        allow =
          Enum.find(policies, fn p ->
            p.effect == :allow and matches_conditions?(p, subject, action, resource)
          end)

        case allow do
          %Policy{} = p -> {:allow, p}
          nil -> :not_applicable
        end
    end
  end

  @spec matches_conditions?(Policy.t(), subject(), action(), resource()) :: boolean()
  defp matches_conditions?(policy, subject, _action, resource) do
    role_match = policy.required_roles == [] or Enum.any?(policy.required_roles, &(&1 in subject.roles))
    attribute_match = attributes_satisfy?(policy.conditions, subject.attributes, resource.attributes)
    role_match and attribute_match
  end

  @spec attributes_satisfy?([map()], map(), map()) :: boolean()
  defp attributes_satisfy?([], _subject_attrs, _resource_attrs), do: true

  defp attributes_satisfy?(conditions, subject_attrs, resource_attrs) do
    Enum.all?(conditions, fn condition ->
      value =
        case condition.source do
          :subject -> Map.get(subject_attrs, condition.attribute)
          :resource -> Map.get(resource_attrs, condition.attribute)
        end

      evaluate_condition(condition.operator, value, condition.expected)
    end)
  end

  @spec evaluate_condition(atom(), term(), term()) :: boolean()
  defp evaluate_condition(:eq, actual, expected), do: actual == expected
  defp evaluate_condition(:neq, actual, expected), do: actual != expected
  defp evaluate_condition(:in, actual, expected) when is_list(expected), do: actual in expected
  defp evaluate_condition(:gt, actual, expected), do: is_number(actual) and actual > expected
  defp evaluate_condition(:lt, actual, expected), do: is_number(actual) and actual < expected
  defp evaluate_condition(:exists, actual, _), do: not is_nil(actual)
  defp evaluate_condition(_, _, _), do: false
end
```
