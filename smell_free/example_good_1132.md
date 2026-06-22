```elixir
defmodule Flagsmith.Evaluator do
  @moduledoc """
  Pure functional engine for evaluating feature flags against a targeting context.
  Supports percentage rollouts, allowlist targeting, attribute-based rules,
  and default fallback values. Returns deterministic results for a given context.
  """

  alias Flagsmith.{Flag, Rule, Context}

  @type evaluation :: %{
          flag_key: String.t(),
          value: boolean() | String.t() | integer(),
          matched_rule: String.t() | nil,
          reason: :rule_match | :rollout | :default
        }

  @spec evaluate(Flag.t(), Context.t()) :: evaluation()
  def evaluate(%Flag{} = flag, %Context{} = context) do
    case find_matching_rule(flag.rules, context) do
      {:matched, rule} ->
        %{
          flag_key: flag.key,
          value: rule.serve_value,
          matched_rule: rule.name,
          reason: :rule_match
        }

      :no_match ->
        resolve_rollout_or_default(flag, context)
    end
  end

  @spec evaluate_many([Flag.t()], Context.t()) :: %{String.t() => evaluation()}
  def evaluate_many(flags, %Context{} = context) when is_list(flags) do
    Map.new(flags, fn flag -> {flag.key, evaluate(flag, context)} end)
  end

  @spec find_matching_rule([Rule.t()], Context.t()) ::
          {:matched, Rule.t()} | :no_match
  defp find_matching_rule(rules, context) do
    Enum.find_value(rules, :no_match, fn rule ->
      if rule_matches?(rule, context), do: {:matched, rule}
    end)
  end

  @spec rule_matches?(Rule.t(), Context.t()) :: boolean()
  defp rule_matches?(%Rule{type: :allowlist, values: values}, context) do
    context.identifier in values
  end

  defp rule_matches?(%Rule{type: :attribute, attribute: attr, operator: op, values: values}, context) do
    ctx_value = Map.get(context.attributes, attr)
    evaluate_operator(op, ctx_value, values)
  end

  defp rule_matches?(%Rule{type: :percentage, percentage: pct}, context) do
    bucket = hash_to_bucket(context.identifier)
    bucket < pct
  end

  @spec evaluate_operator(atom(), term(), [String.t()]) :: boolean()
  defp evaluate_operator(:in, value, values) when is_binary(value), do: value in values
  defp evaluate_operator(:not_in, value, values) when is_binary(value), do: value not in values
  defp evaluate_operator(:equals, value, [expected]), do: to_string(value) == expected
  defp evaluate_operator(_, _value, _values), do: false

  @spec resolve_rollout_or_default(Flag.t(), Context.t()) :: evaluation()
  defp resolve_rollout_or_default(%Flag{rollout_percentage: pct} = flag, context)
       when is_integer(pct) and pct > 0 do
    bucket = hash_to_bucket(context.identifier)

    if bucket < pct do
      %{
        flag_key: flag.key,
        value: flag.on_value,
        matched_rule: nil,
        reason: :rollout
      }
    else
      build_default(flag)
    end
  end

  defp resolve_rollout_or_default(flag, _context), do: build_default(flag)

  @spec build_default(Flag.t()) :: evaluation()
  defp build_default(flag) do
    %{flag_key: flag.key, value: flag.default_value, matched_rule: nil, reason: :default}
  end

  @spec hash_to_bucket(String.t()) :: integer()
  defp hash_to_bucket(identifier) do
    :erlang.phash2(identifier, 100)
  end
end

defmodule Flagsmith.Flag do
  @moduledoc "Struct representing a named feature flag with its targeting configuration."

  alias Flagsmith.Rule

  @type t :: %__MODULE__{
          key: String.t(),
          on_value: boolean() | String.t() | integer(),
          default_value: boolean() | String.t() | integer(),
          rollout_percentage: integer() | nil,
          rules: [Rule.t()]
        }

  @enforce_keys [:key, :on_value, :default_value]
  defstruct [:key, :on_value, :default_value, rollout_percentage: nil, rules: []]
end

defmodule Flagsmith.Rule do
  @moduledoc "Struct representing a single targeting rule within a feature flag."

  @type rule_type :: :allowlist | :attribute | :percentage

  @type t :: %__MODULE__{
          name: String.t(),
          type: rule_type(),
          serve_value: boolean() | String.t() | integer(),
          values: [String.t()],
          attribute: String.t() | nil,
          operator: atom() | nil,
          percentage: integer() | nil
        }

  @enforce_keys [:name, :type, :serve_value]
  defstruct [:name, :type, :serve_value, :attribute, :operator, :percentage, values: []]
end

defmodule Flagsmith.Context do
  @moduledoc "Evaluation context identifying the subject and their attributes."

  @type t :: %__MODULE__{
          identifier: String.t(),
          attributes: %{String.t() => term()}
        }

  @enforce_keys [:identifier]
  defstruct [:identifier, attributes: %{}]

  @spec new(String.t(), map()) :: t()
  def new(identifier, attributes \\ %{}) when is_binary(identifier) and is_map(attributes) do
    %__MODULE__{identifier: identifier, attributes: attributes}
  end
end
```
