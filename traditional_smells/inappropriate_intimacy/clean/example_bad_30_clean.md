```elixir
defmodule MyApp.Platform.FeatureToggleResolver do
  @moduledoc """
  Resolves whether a given feature flag is active for a specific tenant and user.
  Applies tenant-level overrides, beta cohort membership, percentage rollouts,
  segment targeting, and kill switches in a defined precedence order.
  """

  alias MyApp.Platform.{TenantConfig, RolloutRule}
  alias MyApp.Accounts.User
  alias MyApp.Platform.ToggleAuditLog

  @precedence [:kill_switch, :tenant_override, :beta_cohort, :segment, :percentage, :default]

  def resolve(feature_key, context) do
    tenant_id = Map.fetch!(context, :tenant_id)
    user_id   = Map.fetch!(context, :user_id)

    tenant_config = TenantConfig.for_tenant(tenant_id)
    rollout_rule  = RolloutRule.for_feature(feature_key)

    enabled_features = tenant_config.enabled_features
    overrides        = tenant_config.overrides
    beta_cohort_ids  = tenant_config.beta_cohort_ids

    rollout_pct      = rollout_rule && rollout_rule.rollout_percentage
    target_segments  = rollout_rule && rollout_rule.target_segments
    kill_switch      = rollout_rule && rollout_rule.kill_switch

    user = User.fetch!(user_id)

    decision =
      Enum.reduce_while(@precedence, :default_off, fn step, _acc ->
        case step do
          :kill_switch when kill_switch == true ->
            {:halt, {:off, :kill_switch}}

          :tenant_override ->
            case Map.get(overrides, feature_key) do
              true  -> {:halt, {:on, :tenant_override}}
              false -> {:halt, {:off, :tenant_override}}
              nil   -> {:cont, :no_decision}
            end

          :beta_cohort ->
            if user_id in beta_cohort_ids do
              {:halt, {:on, :beta_cohort}}
            else
              {:cont, :no_decision}
            end

          :segment ->
            segments = user.segments || []
            if target_segments != nil and Enum.any?(segments, &(&1 in target_segments)) do
              {:halt, {:on, :segment_match}}
            else
              {:cont, :no_decision}
            end

          :percentage ->
            bucket = :erlang.phash2({feature_key, user_id}, 100)
            if rollout_pct != nil and bucket < rollout_pct do
              {:halt, {:on, :percentage_rollout}}
            else
              {:cont, :no_decision}
            end

          :default ->
            if feature_key in enabled_features do
              {:halt, {:on, :tenant_default}}
            else
              {:halt, {:off, :not_enabled}}
            end

          _ ->
            {:cont, :no_decision}
        end
      end)

    {enabled, reason} =
      case decision do
        {state, r} -> {state == :on, r}
        _          -> {false, :unknown}
      end

    ToggleAuditLog.record(feature_key, tenant_id, user_id, enabled, reason)

    {:ok, %{feature: feature_key, enabled: enabled, reason: reason}}
  end

  def resolve_many(feature_keys, context) when is_list(feature_keys) do
    Map.new(feature_keys, fn key ->
      {:ok, result} = resolve(key, context)
      {key, result.enabled}
    end)
  end

  def enabled?(feature_key, context) do
    case resolve(feature_key, context) do
      {:ok, %{enabled: true}} -> true
      _                       -> false
    end
  end

  def override(tenant_id, feature_key, value) when is_boolean(value) do
    TenantConfig.set_override(tenant_id, feature_key, value)
  end

  def clear_override(tenant_id, feature_key) do
    TenantConfig.clear_override(tenant_id, feature_key)
  end
end
```
