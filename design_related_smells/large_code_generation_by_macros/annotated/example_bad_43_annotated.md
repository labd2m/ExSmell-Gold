# Annotated Example — Code Smell: Large code generation by macros

## Metadata

| Field                    | Detail                                                                                          |
|--------------------------|-------------------------------------------------------------------------------------------------|
| **Smell name**           | Large code generation by macros                                                                 |
| **Expected smell location** | `defmacro plan/3`, lines ~60–120                                                            |
| **Affected function(s)** | `plan/3`                                                                                        |
| **Explanation**          | Each `plan/3` call expands a large `quote` block that validates the price, normalises feature lists, writes module attributes, and generates three public functions (`price/0`, `features/0`, `includes?/1`). With one call per subscription tier, all of this validation and function-generation code is separately compiled into the module, ballooning the compiled bytecode instead of delegating the heavy lifting to a plain helper function. |

---

```elixir
defmodule MyApp.Billing.PlanRegistry do
  @moduledoc """
  DSL for declaring subscription plans and their associated features.

  ## Usage

      defmodule MyApp.Billing.Plans do
        use MyApp.Billing.PlanRegistry

        plan :free,       price_cents: 0,      features: [:api_access, :dashboard]
        plan :starter,    price_cents: 1900,   features: [:api_access, :dashboard, :exports, :webhooks]
        plan :pro,        price_cents: 4900,   features: [:api_access, :dashboard, :exports,
                                                           :webhooks, :sso, :audit_log]
        plan :enterprise, price_cents: 19_900, features: [:api_access, :dashboard, :exports,
                                                           :webhooks, :sso, :audit_log,
                                                           :custom_domain, :dedicated_support]
      end
  """

  @known_features [
    :api_access, :dashboard, :exports, :webhooks,
    :sso, :audit_log, :custom_domain, :dedicated_support,
    :advanced_reporting, :white_label
  ]

  defmacro __using__(_opts) do
    quote do
      import MyApp.Billing.PlanRegistry, only: [plan: 2]
      Module.register_attribute(__MODULE__, :registered_plans, accumulate: true)
      @before_compile MyApp.Billing.PlanRegistry
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc "Returns a list of all registered plan names."
      def all_plans, do: Enum.map(@registered_plans, &elem(&1, 0))

      @doc "Returns the full plan map for a given plan name, or nil."
      def fetch_plan(name) do
        Enum.find_value(@registered_plans, fn {n, p, f} ->
          if n == name, do: %{name: n, price_cents: p, features: f}
        end)
      end

      @doc "Returns true if `plan_name` can be upgraded to `target_plan_name`."
      def upgradeable?(plan_name, target_plan_name) do
        plans = Enum.map(@registered_plans, &elem(&1, 0))
        idx_current = Enum.find_index(plans, &(&1 == plan_name))
        idx_target  = Enum.find_index(plans, &(&1 == target_plan_name))
        not is_nil(idx_current) and not is_nil(idx_target) and idx_target > idx_current
      end
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because every call to plan/2 expands this entire quote block
  # into the caller's module: keyword-option extraction, price validation (with boundary
  # checks), feature-list validation (including an Enum.each loop), a module-attribute
  # write, and three complete function definitions (plan_NAME_price/0, plan_NAME_features/0,
  # plan_NAME_includes?/1). A module registering four tiers compiles all of this four times
  # over. The validation and function bodies should instead be delegated to a plain
  # `__register_plan__/4` function, leaving only a minimal quote in the macro.
  defmacro plan(name, opts) do
    quote do
      unless is_atom(unquote(name)) do
        raise ArgumentError,
              "plan/2 expects an atom name, got: #{inspect(unquote(name))}"
      end

      price_cents = Keyword.get(unquote(opts), :price_cents)
      features    = Keyword.get(unquote(opts), :features, [])

      unless is_integer(price_cents) and price_cents >= 0 do
        raise ArgumentError,
              "plan #{inspect(unquote(name))}: :price_cents must be a non-negative integer, " <>
                "got: #{inspect(price_cents)}"
      end

      unless price_cents <= 1_000_000 do
        raise ArgumentError,
              "plan #{inspect(unquote(name))}: :price_cents exceeds maximum allowed value of 1_000_000"
      end

      unless is_list(features) do
        raise ArgumentError,
              "plan #{inspect(unquote(name))}: :features must be a list of atoms, " <>
                "got: #{inspect(features)}"
      end

      Enum.each(features, fn feat ->
        unless feat in unquote(@known_features) do
          raise ArgumentError,
                "plan #{inspect(unquote(name))}: unknown feature #{inspect(feat)}. " <>
                  "Known features: #{inspect(unquote(@known_features))}"
        end
      end)

      @registered_plans {unquote(name), price_cents, features}

      @doc "Returns the price in cents for the #{unquote(name)} plan."
      def unquote(:"plan_#{name}_price")(), do: price_cents

      @doc "Returns the feature list for the #{unquote(name)} plan."
      def unquote(:"plan_#{name}_features")(), do: features

      @doc "Returns true when `feature` is included in the #{unquote(name)} plan."
      def unquote(:"plan_#{name}_includes?")(feature) do
        feature in features
      end
    end
  end
  # VALIDATION: SMELL END

  @doc "Returns all features known to the billing system."
  def known_features, do: @known_features
end
```
