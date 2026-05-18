# Annotated Example — Code Smell

## Metadata

- **Smell name:** Dynamic atom creation
- **Expected smell location:** `to_feature_key/1` function
- **Affected function(s):** `to_feature_key/1`, `evaluate/2`
- **Short explanation:** The function converts a feature flag name string provided by the caller at runtime into an atom using `String.to_atom/1`. Feature flag names can originate from configuration files, databases, or API responses and grow as the product evolves, making this an uncontrolled source of atoms with no compile-time bound.

---

```elixir
defmodule FeatureFlags.Evaluator do
  @moduledoc """
  Evaluates feature flag states for a given user context.
  Flags are stored in a remote configuration service and cached locally.
  """

  require Logger

  alias FeatureFlags.{ConfigClient, FlagCache, UserSegment, AuditTrail}

  @cache_ttl_seconds 60
  @default_state false

  @spec evaluate(String.t(), map()) :: {:ok, boolean()} | {:error, term()}
  def evaluate(flag_name, user_context) when is_binary(flag_name) do
    with {:ok, flag_key} <- to_feature_key(flag_name),
         {:ok, flag_config} <- fetch_flag(flag_key),
         {:ok, result} <- compute_result(flag_config, user_context) do
      AuditTrail.log_evaluation(flag_name, user_context[:user_id], result)
      {:ok, result}
    else
      {:error, :not_found} ->
        Logger.debug("Feature flag not found, defaulting", flag: flag_name)
        {:ok, @default_state}

      {:error, reason} = err ->
        Logger.error("Feature flag evaluation failed",
          flag: flag_name,
          reason: inspect(reason)
        )
        err
    end
  end

  @spec evaluate_many([String.t()], map()) :: {:ok, map()} | {:error, term()}
  def evaluate_many(flag_names, user_context) when is_list(flag_names) do
    results =
      Enum.reduce_while(flag_names, {:ok, %{}}, fn name, {:ok, acc} ->
        case evaluate(name, user_context) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    results
  end

  defp fetch_flag(flag_key) do
    case FlagCache.get(flag_key) do
      {:hit, config} ->
        {:ok, config}

      :miss ->
        case ConfigClient.fetch_flag(Atom.to_string(flag_key)) do
          {:ok, config} ->
            FlagCache.put(flag_key, config, ttl: @cache_ttl_seconds)
            {:ok, config}

          {:error, _} = err ->
            err
        end
    end
  end

  defp compute_result(%{enabled: false}, _user_context), do: {:ok, false}
  defp compute_result(%{enabled: true, rollout_percentage: 100}, _), do: {:ok, true}

  defp compute_result(%{enabled: true, rollout_percentage: pct, segments: segments}, ctx) do
    in_segment = segments == [] or UserSegment.member?(ctx[:user_id], segments)
    in_rollout = UserSegment.in_percentage_rollout?(ctx[:user_id], pct)
    {:ok, in_segment and in_rollout}
  end

  defp compute_result(%{enabled: true}, _), do: {:ok, true}
  defp compute_result(_, _), do: {:ok, @default_state}

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is applied to the
  # feature flag name string, which originates from callers across the
  # codebase or from external systems (config services, A/B test platforms).
  # As new feature flags are added to the product over time, each flag name
  # produces a new permanent atom. There is no compile-time bound on how many
  # flag names will exist, so the atom table grows without developer control.
  defp to_feature_key(name) when is_binary(name) do
    key =
      name
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]/, "_")
      |> String.to_atom()

    {:ok, key}
  end
  # VALIDATION: SMELL END

  defp to_feature_key(_), do: {:error, :invalid_flag_name}
end
```
