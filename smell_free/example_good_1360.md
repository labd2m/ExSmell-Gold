```elixir
defmodule Rules.Condition do
  @moduledoc """
  A single predicate that tests a value from a fact map using a named operator.
  Conditions are pure data — no closures, no captured state.
  """

  @enforce_keys [:field, :operator, :value]
  defstruct [:field, :operator, :value]

  @type operator :: :eq | :neq | :gt | :lt | :gte | :lte | :in | :not_in | :contains
  @type t :: %__MODULE__{field: atom(), operator: operator(), value: term()}

  @spec new(atom(), operator(), term()) :: t()
  def new(field, operator, value) when is_atom(field) and is_atom(operator) do
    %__MODULE__{field: field, operator: operator, value: value}
  end

  @spec evaluate(t(), map()) :: boolean()
  def evaluate(%__MODULE__{field: field, operator: op, value: expected}, facts)
      when is_map(facts) do
    actual = Map.get(facts, field)
    apply_operator(op, actual, expected)
  end

  defp apply_operator(:eq, actual, expected), do: actual == expected
  defp apply_operator(:neq, actual, expected), do: actual != expected
  defp apply_operator(:gt, actual, expected) when is_number(actual) and is_number(expected), do: actual > expected
  defp apply_operator(:lt, actual, expected) when is_number(actual) and is_number(expected), do: actual < expected
  defp apply_operator(:gte, actual, expected) when is_number(actual) and is_number(expected), do: actual >= expected
  defp apply_operator(:lte, actual, expected) when is_number(actual) and is_number(expected), do: actual <= expected
  defp apply_operator(:in, actual, expected) when is_list(expected), do: actual in expected
  defp apply_operator(:not_in, actual, expected) when is_list(expected), do: actual not in expected
  defp apply_operator(:contains, actual, expected) when is_binary(actual) and is_binary(expected), do: String.contains?(actual, expected)
  defp apply_operator(_, _, _), do: false
end

defmodule Rules.Rule do
  @moduledoc """
  A named rule with a list of conditions (all must match) and an action to apply.
  """

  alias Rules.Condition

  @enforce_keys [:name, :conditions, :action]
  defstruct [:name, :conditions, :action, :priority]

  @type t :: %__MODULE__{
          name: atom(),
          conditions: list(Condition.t()),
          action: atom() | map(),
          priority: integer() | nil
        }

  @spec new(atom(), list(Condition.t()), atom() | map(), keyword()) :: t()
  def new(name, conditions, action, opts \\ []) when is_atom(name) and is_list(conditions) do
    %__MODULE__{
      name: name,
      conditions: conditions,
      action: action,
      priority: Keyword.get(opts, :priority, 0)
    }
  end

  @spec matches?(t(), map()) :: boolean()
  def matches?(%__MODULE__{conditions: conditions}, facts) when is_map(facts) do
    Enum.all?(conditions, &Condition.evaluate(&1, facts))
  end
end

defmodule Rules.Engine do
  @moduledoc """
  Evaluates a prioritized list of rules against a fact map.
  Returns all matching rules sorted by priority, or the first match
  in `:first_match` mode.
  """

  alias Rules.Rule

  @type mode :: :all_matches | :first_match
  @type result :: %{rule: Rule.t(), action: term()}

  @spec evaluate(list(Rule.t()), map(), mode()) :: list(result())
  def evaluate(rules, facts, mode \\ :all_matches)
      when is_list(rules) and is_map(facts) and mode in [:all_matches, :first_match] do
    sorted = Enum.sort_by(rules, & &1.priority, :desc)
    apply_mode(sorted, facts, mode)
  end

  @spec evaluate_one(list(Rule.t()), map()) :: {:ok, result()} | {:error, :no_match}
  def evaluate_one(rules, facts) when is_list(rules) and is_map(facts) do
    case evaluate(rules, facts, :first_match) do
      [result | _] -> {:ok, result}
      [] -> {:error, :no_match}
    end
  end

  defp apply_mode(sorted, facts, :all_matches) do
    sorted
    |> Enum.filter(&Rule.matches?(&1, facts))
    |> Enum.map(fn rule -> %{rule: rule, action: rule.action} end)
  end

  defp apply_mode(sorted, facts, :first_match) do
    sorted
    |> Enum.find(&Rule.matches?(&1, facts))
    |> case do
      nil -> []
      rule -> [%{rule: rule, action: rule.action}]
    end
  end
end
```
