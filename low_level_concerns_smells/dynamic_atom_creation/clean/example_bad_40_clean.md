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

  defp to_feature_key(name) when is_binary(name) do
    key =
      name
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]/, "_")
      |> String.to_atom()

    {:ok, key}
  end

  defp to_feature_key(_), do: {:error, :invalid_flag_name}
end
```
