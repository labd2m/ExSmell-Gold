```elixir
defmodule FeatureFlags.Evaluator do
  @moduledoc """
  Evaluates feature flag rules against a request context to determine
  whether a flag is enabled. Supports percentage rollouts, explicit
  allowlists, and environment overrides without global mutable state.
  """

  alias FeatureFlags.{FlagStore, RuleEngine}

  @type flag_name :: atom()

  @type evaluation_context :: %{
          user_id: String.t(),
          environment: :production | :staging | :development,
          attributes: map()
        }

  @type flag_result :: %{
          enabled: boolean(),
          flag: flag_name(),
          matched_rule: atom() | nil
        }

  @spec enabled?(flag_name(), evaluation_context()) :: boolean()
  def enabled?(flag_name, context) when is_atom(flag_name) do
    flag_name
    |> evaluate(context)
    |> Map.fetch!(:enabled)
  end

  @spec evaluate(flag_name(), evaluation_context()) :: flag_result()
  def evaluate(flag_name, context) when is_atom(flag_name) do
    case FlagStore.fetch(flag_name) do
      {:ok, flag} -> apply_rules(flag, context)
      {:error, :not_found} -> disabled_result(flag_name)
    end
  end

  @spec evaluate_many([flag_name()], evaluation_context()) :: %{flag_name() => flag_result()}
  def evaluate_many(flag_names, context) when is_list(flag_names) do
    Map.new(flag_names, fn name -> {name, evaluate(name, context)} end)
  end

  @spec apply_rules(map(), evaluation_context()) :: flag_result()
  defp apply_rules(%{globally_disabled: true} = flag, _context) do
    %{enabled: false, flag: flag.name, matched_rule: :globally_disabled}
  end

  defp apply_rules(%{environment_override: overrides} = flag, %{environment: env} = context)
       when is_map(overrides) do
    case Map.get(overrides, env) do
      nil -> evaluate_targeting_rules(flag, context)
      override_value -> %{enabled: override_value, flag: flag.name, matched_rule: :env_override}
    end
  end

  defp apply_rules(flag, context), do: evaluate_targeting_rules(flag, context)

  @spec evaluate_targeting_rules(map(), evaluation_context()) :: flag_result()
  defp evaluate_targeting_rules(flag, context) do
    case find_matching_rule(flag.rules, context) do
      {:match, rule_name, value} ->
        %{enabled: value, flag: flag.name, matched_rule: rule_name}

      :no_match ->
        rollout_result = RuleEngine.check_percentage_rollout(flag, context.user_id)
        %{enabled: rollout_result, flag: flag.name, matched_rule: :percentage_rollout}
    end
  end

  @spec find_matching_rule([map()], evaluation_context()) ::
          {:match, atom(), boolean()} | :no_match
  defp find_matching_rule([], _context), do: :no_match

  defp find_matching_rule([rule | rest], context) do
    if RuleEngine.matches?(rule, context) do
      {:match, rule.name, rule.value}
    else
      find_matching_rule(rest, context)
    end
  end

  @spec disabled_result(flag_name()) :: flag_result()
  defp disabled_result(flag_name) do
    %{enabled: false, flag: flag_name, matched_rule: nil}
  end
end
```
