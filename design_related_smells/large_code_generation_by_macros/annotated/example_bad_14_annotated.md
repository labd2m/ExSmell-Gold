# Annotated Example 14 — Large Code Generation by Macros

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro defrule/2` inside `Validation.RuleDSL`
- **Affected function(s):** `defrule/2`
- **Short explanation:** The macro expands a sizable block—field type assertions, constraint checks (min/max), pattern validation, error-message format check, and attribute registration—inside the quoted block for every validation rule. All call sites expand and compile this body separately instead of delegating to a helper function.

---

```elixir
defmodule Validation.RuleDSL do
  @moduledoc """
  Compile-time DSL for declaring named validation rules.

  Each rule binds a field name, an expected type, optional constraints such
  as min/max length or value, a custom error message, and an optional regex
  pattern. Rules are registered at compile time and used by the
  `Validation.Validator` module to validate changesets.
  """

  @valid_types [:string, :integer, :float, :boolean, :date, :datetime, :uuid]

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because defrule/2 inlines all validation—
  # VALIDATION: type check, min/max constraint checks, regex pattern check,
  # VALIDATION: error-message format check, and attribute registration—inside
  # VALIDATION: the quoted block. The compiler re-expands and recompiles this
  # VALIDATION: body for every single rule declaration rather than delegating
  # VALIDATION: the bulk to a helper function compiled once.
  defmacro defrule(rule_name, opts) do
    quote do
      rule = unquote(rule_name)
      opts = unquote(opts)

      unless is_atom(rule) do
        raise ArgumentError,
              "rule name must be an atom, got: #{inspect(rule)}"
      end

      field = Keyword.fetch!(opts, :field)

      unless is_atom(field) do
        raise ArgumentError,
              "rule #{inspect(rule)} :field must be an atom"
      end

      type = Keyword.fetch!(opts, :type)

      unless type in unquote(@valid_types) do
        raise ArgumentError,
              "rule #{inspect(rule)} :type must be one of #{inspect(unquote(@valid_types))}"
      end

      required = Keyword.get(opts, :required, false)

      unless is_boolean(required) do
        raise ArgumentError,
              "rule #{inspect(rule)} :required must be a boolean"
      end

      min = Keyword.get(opts, :min)

      if min != nil do
        unless is_number(min) do
          raise ArgumentError,
                "rule #{inspect(rule)} :min must be a number"
        end
      end

      max = Keyword.get(opts, :max)

      if max != nil do
        unless is_number(max) do
          raise ArgumentError,
                "rule #{inspect(rule)} :max must be a number"
        end
      end

      if min != nil and max != nil and min > max do
        raise ArgumentError,
              "rule #{inspect(rule)} :min (#{min}) must be <= :max (#{max})"
      end

      pattern = Keyword.get(opts, :pattern)

      if pattern != nil do
        unless is_struct(pattern, Regex) do
          raise ArgumentError,
                "rule #{inspect(rule)} :pattern must be a compiled Regex struct"
        end
      end

      error_message = Keyword.get(opts, :error_message, "is invalid")

      unless is_binary(error_message) do
        raise ArgumentError,
              "rule #{inspect(rule)} :error_message must be a binary"
      end

      @validation_rules %{
        name:          rule,
        field:         field,
        type:          type,
        required:      required,
        min:           min,
        max:           max,
        pattern:       pattern,
        error_message: error_message
      }
    end
  end
  # VALIDATION: SMELL END

  defmacro __using__(_) do
    quote do
      import Validation.RuleDSL, only: [defrule: 2]
      Module.register_attribute(__MODULE__, :validation_rules, accumulate: true)
      @before_compile Validation.RuleDSL
    end
  end

  defmacro __before_compile__(env) do
    rules = Module.get_attribute(env.module, :validation_rules)

    quote do
      def rules, do: unquote(Macro.escape(rules))

      def rules_for_field(field) do
        Enum.filter(rules(), &(&1.field == field))
      end

      def required_fields do
        rules()
        |> Enum.filter(& &1.required)
        |> Enum.map(& &1.field)
        |> Enum.uniq()
      end
    end
  end
end

defmodule Validation.UserRules do
  use Validation.RuleDSL

  defrule(:username_present,
    field: :username,
    type: :string,
    required: true,
    min: 3,
    max: 32,
    pattern: ~r/\A[a-z0-9_]+\z/,
    error_message: "must be 3–32 lowercase alphanumeric characters or underscores"
  )

  defrule(:email_format,
    field: :email,
    type: :string,
    required: true,
    pattern: ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/,
    error_message: "must be a valid email address"
  )

  defrule(:password_length,
    field: :password,
    type: :string,
    required: true,
    min: 8,
    max: 128,
    error_message: "must be between 8 and 128 characters"
  )

  defrule(:age_range,
    field: :age,
    type: :integer,
    required: false,
    min: 13,
    max: 120,
    error_message: "must be between 13 and 120"
  )

  defrule(:phone_format,
    field: :phone,
    type: :string,
    required: false,
    pattern: ~r/\A\+[1-9]\d{7,14}\z/,
    error_message: "must be a valid E.164 phone number"
  )

  defrule(:bio_length,
    field: :bio,
    type: :string,
    required: false,
    max: 500,
    error_message: "must be at most 500 characters"
  )

  defrule(:timezone_present,
    field: :timezone,
    type: :string,
    required: true,
    error_message: "must be present"
  )
end
```
