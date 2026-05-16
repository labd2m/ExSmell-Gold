# Code Smell: Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `Config.FeatureFlags.evaluate/2`
- **Affected function(s):** `evaluate/2`
- **Short explanation:** The `:return` option changes the result from a plain boolean, to a `{boolean, reason_atom}` tuple explaining why the flag resolved as it did, to a full `%FlagDecision{}` struct with evaluation context. These shapes are entirely incompatible and make it impossible for generic flag-checking middleware to process results uniformly.

---

```elixir
defmodule MyApp.Config.FeatureFlags do
  @moduledoc """
  Evaluates feature flag states for users, tenants, and environments.
  Supports percentage rollouts, explicit overrides, and kill-switch controls.
  Integrates with the remote flag config store and local override cache.
  """

  alias MyApp.Config.FlagStore
  alias MyApp.Config.RolloutEngine
  alias MyApp.Config.OverrideCache
  alias MyApp.Config.FlagDecision

  @default_flag_state false
  @global_kill_switch :maintenance_mode

  defstruct [
    :flag_key, :result, :reason,
    :rollout_pct, :override_applied,
    :evaluated_at, :context
  ]

  def all_flags do
    FlagStore.list_all()
  end

  def override(flag_key, value, subject_id) do
    OverrideCache.set(flag_key, subject_id, value)
  end

  def clear_override(flag_key, subject_id) do
    OverrideCache.delete(flag_key, subject_id)
  end

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because opts[:return] changes the type:
  # :bool returns a plain boolean (true/false), :tagged returns a
  # {boolean, reason_atom} two-element tuple where the atom is one of
  # :kill_switch, :override, :rollout, :default, and :decision returns a
  # %FlagDecision{} struct with full evaluation context. Middleware that wraps
  # flag evaluation (e.g., for caching or logging) must know the :return option
  # in order to extract the boolean value, breaking composability entirely.
  def evaluate(flag_key, opts \\ []) when is_list(opts) do
    return = Keyword.get(opts, :return, :bool)
    subject_id = Keyword.get(opts, :subject_id)
    context = Keyword.get(opts, :context, %{})

    {result, reason} =
      cond do
        evaluate_kill_switch() ->
          {false, :kill_switch}

        override = subject_id && OverrideCache.get(flag_key, subject_id) ->
          {override, :override}

        flag = FlagStore.get(flag_key) ->
          in_rollout = RolloutEngine.included?(flag, subject_id, context)
          {in_rollout, :rollout}

        true ->
          {@default_flag_state, :default}
      end

    case return do
      :bool ->
        result

      :tagged ->
        {result, reason}

      :decision ->
        rollout_pct =
          case FlagStore.get(flag_key) do
            nil -> nil
            flag -> flag.rollout_percentage
          end

        %__MODULE__{
          flag_key: flag_key,
          result: result,
          reason: reason,
          rollout_pct: rollout_pct,
          override_applied: reason == :override,
          evaluated_at: DateTime.utc_now(),
          context: context
        }
    end
  end
  # VALIDATION: SMELL END

  def enabled?(flag_key, subject_id \\ nil) do
    evaluate(flag_key, subject_id: subject_id, return: :bool)
  end

  def bulk_evaluate(flag_keys, opts \\ []) do
    Map.new(flag_keys, fn key ->
      {key, evaluate(key, Keyword.put(opts, :return, :bool))}
    end)
  end

  defp evaluate_kill_switch do
    evaluate(@global_kill_switch, return: :bool)
  end
end
```
