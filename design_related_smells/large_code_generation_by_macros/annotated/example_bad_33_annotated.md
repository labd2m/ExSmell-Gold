# Annotated Example — Bad Code

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro feature_flag/2` inside `MyApp.FeatureFlags.FlagDSL`
- **Affected function(s):** `feature_flag/2` macro
- **Short explanation:** Every call to `feature_flag/2` expands a large `quote` block that validates the flag name, default value type, rollout percentage, target-group list, description, and owner fields — plus deduplication and struct registration — inline at the call site. The compiler must expand this entire block for every flag declaration rather than calling a single validation function.

---

```elixir
defmodule MyApp.FeatureFlags.FlagDSL do
  @moduledoc """
  DSL for declaring feature flags in a flag-configuration module.

  Example:

      defmodule MyApp.FeatureFlags.AppFlags do
        use MyApp.FeatureFlags.FlagDSL

        feature_flag :new_checkout_flow,
          default:     false,
          rollout:     25,
          groups:      [:beta_users, :internal],
          description: "Enables the redesigned checkout experience",
          owner:       "payments-team"

        feature_flag :dark_mode,
          default:     false,
          rollout:     100,
          description: "Global dark mode toggle",
          owner:       "frontend-team"

        feature_flag :api_v2,
          default:     false,
          rollout:     10,
          groups:      [:developers],
          description: "Enable V2 API endpoints",
          owner:       "platform-team"
      end
  """

  defmacro __using__(_opts) do
    quote do
      import MyApp.FeatureFlags.FlagDSL, only: [feature_flag: 2]
      Module.register_attribute(__MODULE__, :flags, accumulate: true)
      @before_compile MyApp.FeatureFlags.FlagDSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def flags, do: @flags

      def flag(name) do
        Enum.find(@flags, fn f -> f.name == name end)
      end

      def enabled_for?(flag_name, context) do
        MyApp.FeatureFlags.FlagDSL.evaluate(__MODULE__.flag(flag_name), context)
      end
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because each call to feature_flag/2 causes the
  # VALIDATION: Elixir compiler to expand and compile: atom-name check, boolean
  # VALIDATION: default check, rollout integer range check, groups list-of-atoms
  # VALIDATION: check, description string check, owner string check, and
  # VALIDATION: deduplication guard — all inline. An application with 50 feature
  # VALIDATION: flags compiles this entire block 50 times instead of delegating
  # VALIDATION: to a shared function once.
  defmacro feature_flag(name, opts) do
    quote do
      name = unquote(name)
      opts = unquote(opts)

      unless is_atom(name) do
        raise ArgumentError,
              "feature_flag/2: name must be an atom, got #{inspect(name)}"
      end

      default = Keyword.get(opts, :default, false)

      unless is_boolean(default) do
        raise ArgumentError,
              "feature_flag/2: :default must be a boolean, got #{inspect(default)}"
      end

      rollout = Keyword.get(opts, :rollout, 0)

      unless is_integer(rollout) and rollout >= 0 and rollout <= 100 do
        raise ArgumentError,
              "feature_flag/2: :rollout must be an integer in [0, 100], " <>
                "got #{inspect(rollout)}"
      end

      groups = Keyword.get(opts, :groups, [])

      unless is_list(groups) and Enum.all?(groups, &is_atom/1) do
        raise ArgumentError,
              "feature_flag/2: :groups must be a list of atoms, got #{inspect(groups)}"
      end

      description = Keyword.get(opts, :description, "")

      unless is_binary(description) do
        raise ArgumentError,
              "feature_flag/2: :description must be a string, got #{inspect(description)}"
      end

      owner = Keyword.get(opts, :owner, "unknown")

      unless is_binary(owner) and byte_size(owner) > 0 do
        raise ArgumentError,
              "feature_flag/2: :owner must be a non-empty string, got #{inspect(owner)}"
      end

      existing = Module.get_attribute(__MODULE__, :flags)

      if Enum.any?(existing, fn f -> f.name == name end) do
        raise ArgumentError,
              "feature_flag/2: duplicate flag #{inspect(name)} in #{inspect(__MODULE__)}"
      end

      flag = %{
        name:        name,
        default:     default,
        rollout:     rollout,
        groups:      groups,
        description: description,
        owner:       owner
      }

      @flags flag
    end
  end
  # VALIDATION: SMELL END

  @doc false
  def evaluate(nil, _context), do: false

  def evaluate(%{rollout: 100, groups: []}, _context), do: true

  def evaluate(%{rollout: rollout, groups: groups, default: default}, context) do
    user_id   = Map.get(context, :user_id, 0)
    user_group = Map.get(context, :group)

    in_group = groups == [] or user_group in groups
    in_rollout = :erlang.phash2(user_id, 100) < rollout

    in_group and in_rollout
  rescue
    _ -> default
  end
end
```
