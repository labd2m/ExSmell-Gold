# Annotated Example 12 — Large Code Generation by Macros

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro defflag/2` inside `FeatureFlags.FlagDSL`
- **Affected function(s):** `defflag/2`
- **Short explanation:** The macro expands a full block of validation—rollout strategy, percentage bounds, targeting rules, kill-switch check, and attribute registration—inline on every flag declaration. Each call site causes the compiler to expand and compile this body again rather than delegating to a plain helper function.

---

```elixir
defmodule FeatureFlags.FlagDSL do
  @moduledoc """
  Compile-time DSL for declaring feature flags.

  Each flag carries a rollout strategy, an optional percentage, optional
  allow/deny lists for specific users or cohorts, and a kill-switch state.
  Flags are registered as module attributes and resolved at runtime by
  the `FeatureFlags.Resolver`.
  """

  @valid_strategies [:all, :none, :percentage, :allowlist, :cohort]

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because defflag/2 places validation for
  # VALIDATION: strategy, percentage, allowlist, cohort list, description,
  # VALIDATION: and kill-switch all inside the quoted block. Each flag
  # VALIDATION: declaration causes the compiler to expand and compile this
  # VALIDATION: whole body independently, instead of delegating the bulk of
  # VALIDATION: the work to a function compiled once.
  defmacro defflag(flag_name, opts \\ []) do
    quote do
      flag = unquote(flag_name)
      opts = unquote(opts)

      unless is_atom(flag) do
        raise ArgumentError,
              "flag name must be an atom, got: #{inspect(flag)}"
      end

      description = Keyword.get(opts, :description, "")

      unless is_binary(description) do
        raise ArgumentError,
              "flag #{inspect(flag)} :description must be a binary"
      end

      strategy = Keyword.get(opts, :strategy, :none)

      unless strategy in unquote(@valid_strategies) do
        raise ArgumentError,
              "flag #{inspect(flag)} :strategy must be one of #{inspect(unquote(@valid_strategies))}"
      end

      percentage = Keyword.get(opts, :percentage)

      if strategy == :percentage do
        unless is_number(percentage) and percentage >= 0 and percentage <= 100 do
          raise ArgumentError,
                "flag #{inspect(flag)} :percentage must be a number between 0 and 100 when strategy is :percentage"
        end
      end

      allowlist = Keyword.get(opts, :allowlist, [])

      unless is_list(allowlist) do
        raise ArgumentError,
              "flag #{inspect(flag)} :allowlist must be a list"
      end

      cohorts = Keyword.get(opts, :cohorts, [])

      unless is_list(cohorts) and Enum.all?(cohorts, &is_atom/1) do
        raise ArgumentError,
              "flag #{inspect(flag)} :cohorts must be a list of atoms"
      end

      kill_switch = Keyword.get(opts, :kill_switch, false)

      unless is_boolean(kill_switch) do
        raise ArgumentError,
              "flag #{inspect(flag)} :kill_switch must be a boolean"
      end

      owner = Keyword.get(opts, :owner, "platform")

      unless is_binary(owner) do
        raise ArgumentError,
              "flag #{inspect(flag)} :owner must be a binary team name"
      end

      @feature_flags %{
        name:        flag,
        description: description,
        strategy:    strategy,
        percentage:  percentage,
        allowlist:   allowlist,
        cohorts:     cohorts,
        kill_switch: kill_switch,
        owner:       owner
      }
    end
  end
  # VALIDATION: SMELL END

  defmacro __using__(_) do
    quote do
      import FeatureFlags.FlagDSL, only: [defflag: 1, defflag: 2]
      Module.register_attribute(__MODULE__, :feature_flags, accumulate: true)
      @before_compile FeatureFlags.FlagDSL
    end
  end

  defmacro __before_compile__(env) do
    flags = Module.get_attribute(env.module, :feature_flags)

    quote do
      def flags, do: unquote(Macro.escape(flags))

      def flag(name) do
        Enum.find(flags(), &(&1.name == name))
      end

      def enabled_for_all?(flag_name) do
        case flag(flag_name) do
          nil  -> false
          flag -> not flag.kill_switch and flag.strategy == :all
        end
      end

      def disabled_for_all?(flag_name) do
        case flag(flag_name) do
          nil  -> true
          flag -> flag.kill_switch or flag.strategy == :none
        end
      end
    end
  end
end

defmodule FeatureFlags.AppFlags do
  use FeatureFlags.FlagDSL

  defflag(:new_checkout_flow,
    description: "Redesigned checkout UI with one-page flow",
    strategy: :percentage,
    percentage: 25,
    owner: "checkout-team"
  )

  defflag(:multi_currency_invoices,
    description: "Allow invoices to be issued in non-USD currencies",
    strategy: :cohort,
    cohorts: [:beta_customers, :enterprise],
    owner: "billing-team"
  )

  defflag(:ai_product_recommendations,
    description: "Show AI-driven product recommendations on listing pages",
    strategy: :none,
    owner: "growth-team"
  )

  defflag(:dark_mode,
    description: "Enable dark mode toggle in user preferences",
    strategy: :all,
    owner: "platform"
  )

  defflag(:shipment_tracking_v2,
    description: "Improved real-time shipment tracking with ETA predictions",
    strategy: :allowlist,
    allowlist: ["user_123", "user_456", "user_789"],
    owner: "logistics-team"
  )

  defflag(:legacy_reports_migration,
    description: "Redirect legacy report URLs to new reporting engine",
    strategy: :percentage,
    percentage: 50,
    kill_switch: true,
    owner: "reporting-team"
  )

  defflag(:instant_payouts,
    description: "Allow merchants to request instant payouts",
    strategy: :cohort,
    cohorts: [:enterprise, :verified_partner],
    owner: "payments-team"
  )

  defflag(:api_v2_endpoints,
    description: "Expose v2 API surface to external developers",
    strategy: :allowlist,
    allowlist: ["dev_partner_a", "dev_partner_b"],
    owner: "platform"
  )
end
```
