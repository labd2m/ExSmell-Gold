```elixir
defmodule FeatureFlags.Evaluator do
  @moduledoc """
  Evaluates feature flag rules for a given actor (user, session, or device).
  Supports boolean flags, multi-variant flags, and audit-friendly explain mode.
  """

  alias FeatureFlags.Repo
  alias FeatureFlags.Schema.{Flag, FlagRule}

  @doc """
  Checks whether a feature flag is enabled for the given actor context.

  ## Arguments

    * `flag_name` — The string name of the feature flag.
    * `actor` — A map with actor context, e.g. `%{user_id: 42, plan: "pro", region: "EU"}`.
    * `opts` — Keyword list of options.

  ## Options

    * `:default` — Value returned when the flag is not found. Defaults to `false`.
    * `:variant` — When `true`, returns the matched variant name as a string
      (e.g., `"control"`, `"treatment_a"`) instead of a boolean. Returns `nil`
      if no variant matches.
    * `:explain` — When `true`, returns a detailed map:
      `%{enabled: boolean, variant: string | nil, reason: string, rule_matched: string | nil}`.
      Overrides `:variant`.

  ## Examples

      iex> check("new_checkout", %{user_id: 1, plan: "pro"})
      true

      iex> check("new_checkout", %{user_id: 1, plan: "pro"}, variant: true)
      "treatment_b"

      iex> check("new_checkout", %{user_id: 1, plan: "pro"}, explain: true)
      %{enabled: true, variant: "treatment_b", reason: "rule matched", rule_matched: "pro_users"}

  """

  def check(flag_name, actor, opts \\ []) when is_binary(flag_name) and is_map(actor) do
    default = Keyword.get(opts, :default, false)
    flag = Repo.get_by(Flag, name: flag_name, active: true)

    if is_nil(flag) do
      resolve_default(default, opts)
    else
      {enabled, variant, rule_name} = evaluate_rules(flag, actor)

      cond do
        opts[:explain] == true ->
          reason = if enabled, do: "rule matched", else: "no matching rule"

          %{
            enabled: enabled,
            variant: variant,
            reason: reason,
            rule_matched: rule_name
          }

        opts[:variant] == true ->
          variant

        true ->
          enabled
      end
    end
  end

  defp resolve_default(default, opts) do
    cond do
      opts[:explain] == true ->
        %{enabled: default, variant: nil, reason: "flag not found", rule_matched: nil}

      opts[:variant] == true ->
        nil

      true ->
        default
    end
  end

  defp evaluate_rules(%Flag{} = flag, actor) do
    rules =
      FlagRule
      |> Repo.all_by(flag_id: flag.id, active: true)
      |> Enum.sort_by(& &1.priority)

    matching_rule = Enum.find(rules, &rule_matches?(&1, actor))

    if matching_rule do
      {true, matching_rule.variant, matching_rule.name}
    else
      {flag.default_enabled, flag.default_variant, nil}
    end
  end

  defp rule_matches?(%FlagRule{conditions: conditions}, actor) do
    Enum.all?(conditions, fn {key, expected} ->
      actual = Map.get(actor, String.to_existing_atom(key))

      case expected do
        %{"op" => "in", "values" => values} -> actual in values
        %{"op" => "eq", "value" => value} -> actual == value
        %{"op" => "neq", "value" => value} -> actual != value
        _ -> false
      end
    end)
  end

  @doc """
  Lists all active flags and their default states.
  """
  def list_active do
    Flag
    |> Repo.all_by(active: true)
    |> Enum.map(&%{name: &1.name, default_enabled: &1.default_enabled})
  end

  @doc """
  Returns the percentage rollout for a flag (0–100), or nil if not rollout-based.
  """
  def rollout_percentage(flag_name) do
    case Repo.get_by(Flag, name: flag_name) do
      nil -> nil
      %Flag{rollout_percentage: pct} -> pct
    end
  end
end
```
