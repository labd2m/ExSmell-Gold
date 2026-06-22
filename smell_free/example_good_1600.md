```elixir
defmodule Flagsmith.Evaluator do
  @moduledoc """
  Evaluates feature flags against actor contexts using a rule-based engine.

  Flags are defined as structs with typed targeting rules. Evaluation is
  pure and stateless: rule resolution does not perform I/O or mutate state.
  """

  alias Flagsmith.{Flag, Rule, Actor}

  @type evaluation :: :enabled | :disabled | {:variant, String.t()}

  @doc """
  Evaluates a flag for the given actor and returns the resolved state.

  Rules are evaluated in priority order; the first matching rule wins.
  Falls back to the flag's default state if no rule matches.
  """
  @spec evaluate(Flag.t(), Actor.t()) :: evaluation()
  def evaluate(%Flag{enabled: false}, _actor), do: :disabled

  def evaluate(%Flag{rules: [], default: default}, _actor), do: default

  def evaluate(%Flag{rules: rules, default: default}, %Actor{} = actor) do
    rules
    |> Enum.sort_by(& &1.priority)
    |> Enum.find(&rule_matches?(&1, actor))
    |> resolve_outcome(default)
  end

  @doc """
  Evaluates a list of flag names for an actor, returning a map of results.
  """
  @spec evaluate_all([Flag.t()], Actor.t()) :: %{String.t() => evaluation()}
  def evaluate_all(flags, %Actor{} = actor) when is_list(flags) do
    Map.new(flags, fn flag -> {flag.name, evaluate(flag, actor)} end)
  end

  # --- rule matching ---

  defp rule_matches?(%Rule{conditions: conditions}, actor) do
    Enum.all?(conditions, &condition_matches?(&1, actor))
  end

  defp condition_matches?(%{attribute: attr, operator: :eq, value: value}, actor) do
    Actor.get_attribute(actor, attr) == value
  end

  defp condition_matches?(%{attribute: attr, operator: :in, value: values}, actor)
       when is_list(values) do
    Actor.get_attribute(actor, attr) in values
  end

  defp condition_matches?(%{attribute: attr, operator: :percentage, value: pct}, actor)
       when is_integer(pct) and pct >= 0 and pct <= 100 do
    bucket = compute_bucket(actor.id, attr)
    bucket < pct
  end

  defp condition_matches?(_, _), do: false

  defp resolve_outcome(nil, default), do: default
  defp resolve_outcome(%Rule{outcome: outcome}, _default), do: outcome

  defp compute_bucket(actor_id, salt) do
    hash = :erlang.phash2("#{salt}:#{actor_id}", 100)
    hash
  end
end

defmodule Flagsmith.Actor do
  @moduledoc "Represents a user or system entity being evaluated against feature flags."

  @enforce_keys [:id]
  defstruct [:id, attributes: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          attributes: map()
        }

  @spec new(String.t(), map()) :: t()
  def new(id, attributes \\ %{}) when is_binary(id) and is_map(attributes) do
    %__MODULE__{id: id, attributes: attributes}
  end

  @spec get_attribute(t(), String.t()) :: term()
  def get_attribute(%__MODULE__{attributes: attrs}, key) when is_binary(key) do
    Map.get(attrs, key)
  end
end

defmodule Flagsmith.Flag do
  @moduledoc "Immutable flag definition with typed targeting rules."

  @enforce_keys [:name, :enabled, :default]
  defstruct [:name, :enabled, :default, rules: []]

  @type t :: %__MODULE__{
          name: String.t(),
          enabled: boolean(),
          default: Flagsmith.Evaluator.evaluation(),
          rules: [Flagsmith.Rule.t()]
        }
end

defmodule Flagsmith.Rule do
  @moduledoc "A single targeting rule within a flag definition."

  @enforce_keys [:priority, :conditions, :outcome]
  defstruct [:priority, :conditions, :outcome]

  @type t :: %__MODULE__{
          priority: non_neg_integer(),
          conditions: [map()],
          outcome: Flagsmith.Evaluator.evaluation()
        }
end
```
