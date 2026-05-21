# Annotated Bad Example 33: Untested Polymorphic Behaviors

## Metadata

- **Smell name**: Untested Polymorphic Behaviors
- **Expected smell location**: `FeatureFlags.RolloutEngine.build_evaluation_context/2`
- **Affected function(s)**: `build_evaluation_context/2`
- **Short explanation**: The function uses string interpolation (which internally calls `to_string/1` via `String.Chars`) on `actor_id` to compose the evaluation context key, without any guard clause. Passing a `Map` (e.g., a full user struct accidentally forwarded without extracting the ID) raises `Protocol.UndefinedError` at runtime. Passing a `Float` silently generates a context key like `"user:3.14e0"` that will never match any rollout segment rule, causing the feature flag to silently evaluate to its default value for that actor — a subtle and hard-to-diagnose rollout failure.

## Code

```elixir
defmodule FeatureFlags.RolloutEngine do
  @moduledoc """
  Evaluates feature flag rollout rules for a given actor context.
  Supports percentage rollouts, explicit allowlists/blocklists, and
  environment-scoped overrides.

  Used by the feature flag SDK, the A/B testing service, and the
  gradual deployment pipeline.
  """

  @hash_modulus 10_000
  @default_environment "production"

  @doc """
  Evaluates a feature flag for an actor and returns whether it is enabled.

  ## Parameters
    - `flag`: A flag config map with `:name`, `:rules`, and `:default` keys.
    - `actor_id`: The identifier of the actor being evaluated.
    - `environment`: The deployment environment string.
  """
  def evaluate(flag, actor_id, environment \\ @default_environment)
      when is_map(flag) and is_binary(environment) do
    context = build_evaluation_context(actor_id, environment)

    flag.rules
    |> Enum.find(&rule_matches?(&1, context))
    |> case do
      nil -> flag.default
      rule -> rule.enabled
    end
  end

  @doc """
  Builds the evaluation context map used to match rollout rules.

  ## Parameters
    - `actor_id`: The actor's unique identifier.
    - `environment`: The deployment environment string.
  """
  # VALIDATION: SMELL START - Untested Polymorphic Behaviors
  # VALIDATION: This is a smell because Elixir string interpolation (`#{}`) calls
  # `to_string/1` via the `String.Chars` protocol on `actor_id` without any guard
  # clause. Passing a full user `Map` (a common accident when the caller forgets
  # to extract `.id`) raises `Protocol.UndefinedError` at runtime. Passing a
  # `Float` silently produces a context key like `"user:9.9e1"` that never matches
  # any rollout segment, causing the flag to silently fall back to its default
  # value for that actor. A guard `is_binary(actor_id) or is_integer(actor_id)`
  # would enforce the correct contract at the function boundary.
  def build_evaluation_context(actor_id, environment) when is_binary(environment) do
    key = "user:#{actor_id}"

    %{
      actor_key: key,
      environment: environment,
      bucket: compute_bucket(key),
      evaluated_at: System.system_time(:second)
    }
  end
  # VALIDATION: SMELL END

  @doc """
  Returns the rollout bucket (0–9999) for a given actor key.
  Used for deterministic percentage-based rollouts.
  """
  def compute_bucket(actor_key) when is_binary(actor_key) do
    :erlang.phash2(actor_key, @hash_modulus)
  end

  @doc """
  Returns whether an actor bucket falls within a percentage rollout threshold.
  `percentage` is an integer from 0 to 100.
  """
  def in_percentage_rollout?(bucket, percentage)
      when is_integer(bucket) and is_integer(percentage) and
             percentage in 0..100 do
    bucket < round(@hash_modulus * percentage / 100)
  end

  @doc """
  Returns a summary of which flags are enabled for a given actor.
  """
  def evaluate_all(flags, actor_id, environment \\ @default_environment)
      when is_list(flags) and is_binary(environment) do
    Map.new(flags, fn flag ->
      {flag.name, evaluate(flag, actor_id, environment)}
    end)
  end

  @doc """
  Returns all flags that differ in evaluation result between two actors.
  Useful for debugging rollout discrepancies.
  """
  def diff_evaluations(flags, actor_id_a, actor_id_b)
      when is_list(flags) and is_binary(actor_id_a) and is_binary(actor_id_b) do
    results_a = evaluate_all(flags, actor_id_a)
    results_b = evaluate_all(flags, actor_id_b)

    Enum.filter(flags, fn flag ->
      Map.get(results_a, flag.name) != Map.get(results_b, flag.name)
    end)
    |> Enum.map(& &1.name)
  end

  # --- Private ---

  defp rule_matches?(%{type: :allowlist, actor_keys: keys}, %{actor_key: key}) do
    key in keys
  end

  defp rule_matches?(%{type: :blocklist, actor_keys: keys}, %{actor_key: key}) do
    key not in keys
  end

  defp rule_matches?(%{type: :percentage, threshold: pct}, %{bucket: bucket}) do
    in_percentage_rollout?(bucket, pct)
  end

  defp rule_matches?(%{type: :environment, environment: env}, %{environment: ctx_env}) do
    env == ctx_env
  end

  defp rule_matches?(_, _), do: false
end
```
