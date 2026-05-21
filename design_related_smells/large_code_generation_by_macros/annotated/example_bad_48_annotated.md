# Annotated Example — Code Smell: Large code generation by macros

## Metadata

| Field                    | Detail                                                                                          |
|--------------------------|-------------------------------------------------------------------------------------------------|
| **Smell name**           | Large code generation by macros                                                                 |
| **Expected smell location** | `defmacro feature/2`, lines ~60–130                                                         |
| **Affected function(s)** | `feature/2`                                                                                     |
| **Explanation**          | Each `feature/2` call expands a `quote` block containing: atom validation, rollout-percentage boundary checks, allowed-plan membership validation with an `Enum.each`, a module-attribute write, and three generated public functions (`feature_FLAGNAME_enabled?/1`, `feature_FLAGNAME_rollout/0`, `feature_FLAGNAME_plans/0`). An application with 20–30 feature flags compiles all this logic 20–30 separate times. The validation and plan-checking should be pushed into a plain helper function rather than repeated in every macro expansion. |

---

```elixir
defmodule MyApp.FeatureFlags do
  @moduledoc """
  DSL for declaring product feature flags with rollout percentages and plan gates.

  Each `feature/2` call registers a flag name, a default rollout percentage,
  and the subscription plans for which the feature is enabled. The DSL also
  generates per-flag helper functions for convenient runtime evaluation.

  ## Usage

      defmodule MyApp.Features do
        use MyApp.FeatureFlags

        feature :new_dashboard,    rollout: 100, plans: [:starter, :pro, :enterprise]
        feature :ai_suggestions,   rollout: 20,  plans: [:pro, :enterprise]
        feature :bulk_exports,     rollout: 100, plans: [:pro, :enterprise]
        feature :advanced_filters, rollout: 50,  plans: [:starter, :pro, :enterprise]
        feature :custom_domain,    rollout: 100, plans: [:enterprise]
        feature :audit_log,        rollout: 100, plans: [:pro, :enterprise]
      end
  """

  @valid_plans [:free, :starter, :pro, :enterprise]

  defmacro __using__(_opts) do
    quote do
      import MyApp.FeatureFlags, only: [feature: 2]
      Module.register_attribute(__MODULE__, :feature_flags, accumulate: true)
      @before_compile MyApp.FeatureFlags
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc "Returns a list of all registered feature flag names."
      def all_flags, do: Enum.map(@feature_flags, &elem(&1, 0))

      @doc """
      Returns `true` when `flag` is enabled for the given `user`.
      Evaluates plan membership and the rollout bucket.
      """
      def enabled?(flag, user) do
        case Enum.find(@feature_flags, fn {f, _, _} -> f == flag end) do
          nil ->
            false

          {_flag, rollout, plans} ->
            plan = Map.get(user, :plan, :free)
            user_id = Map.get(user, :id, 0)
            bucket = rem(user_id, 100)
            plan in plans and bucket < rollout
        end
      end

      @doc "Returns a map of all flags with their rollout and plan configuration."
      def flag_config do
        Map.new(@feature_flags, fn {f, r, p} -> {f, %{rollout: r, plans: p}} end)
      end
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because every call to feature/2 expands the full quote block
  # into the calling module. This includes: an is_atom check on the flag name, rollout
  # extraction with an integer-and-range guard, a plans-list extraction with an Enum.each
  # membership check against @valid_plans, a module-attribute accumulation, and three
  # complete function definitions — feature_FLAGNAME_enabled?/1 (containing plan + rollout
  # bucket logic), feature_FLAGNAME_rollout/0, and feature_FLAGNAME_plans/0. With 25 flags
  # in a typical application, this logic is compiled 25 separate times instead of being
  # delegated once to a plain helper, inflating the .beam file and slowing compilation.
  defmacro feature(flag_name, opts) do
    quote do
      unless is_atom(unquote(flag_name)) do
        raise ArgumentError,
              "feature/2: flag name must be an atom, got: #{inspect(unquote(flag_name))}"
      end

      rollout = Keyword.get(unquote(opts), :rollout, 100)
      plans   = Keyword.get(unquote(opts), :plans, unquote(@valid_plans))

      unless is_integer(rollout) and rollout >= 0 and rollout <= 100 do
        raise ArgumentError,
              "feature/2 #{inspect(unquote(flag_name))}: :rollout must be an integer 0–100, " <>
                "got: #{inspect(rollout)}"
      end

      unless is_list(plans) and length(plans) > 0 do
        raise ArgumentError,
              "feature/2 #{inspect(unquote(flag_name))}: :plans must be a non-empty list, " <>
                "got: #{inspect(plans)}"
      end

      Enum.each(plans, fn plan ->
        unless plan in unquote(@valid_plans) do
          raise ArgumentError,
                "feature/2 #{inspect(unquote(flag_name))}: unknown plan #{inspect(plan)}. " <>
                  "Valid plans: #{inspect(unquote(@valid_plans))}"
        end
      end)

      @feature_flags {unquote(flag_name), rollout, plans}

      @doc """
      Returns `true` when the #{unquote(flag_name)} feature is active for `user`
      based on their plan and rollout bucket.
      """
      def unquote(:"feature_#{flag_name}_enabled?")(user) do
        plan    = Map.get(user, :plan, :free)
        user_id = Map.get(user, :id, 0)
        bucket  = rem(user_id, 100)
        plan in plans and bucket < rollout
      end

      @doc "Returns the rollout percentage configured for #{unquote(flag_name)}."
      def unquote(:"feature_#{flag_name}_rollout")(), do: rollout

      @doc "Returns the plans for which #{unquote(flag_name)} is enabled."
      def unquote(:"feature_#{flag_name}_plans")(), do: plans
    end
  end
  # VALIDATION: SMELL END

  @doc "Returns the list of all billing plans known to the feature flag system."
  def valid_plans, do: @valid_plans
end
```
