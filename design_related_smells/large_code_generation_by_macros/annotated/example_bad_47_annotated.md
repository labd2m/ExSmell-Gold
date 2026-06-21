# Annotated Example — Code Smell: Large code generation by macros

## Metadata

| Field                    | Detail                                                                                          |
|--------------------------|-------------------------------------------------------------------------------------------------|
| **Smell name**           | Large code generation by macros                                                                 |
| **Expected smell location** | `defmacro field/2`, lines ~55–130                                                           |
| **Affected function(s)** | `field/2`                                                                                       |
| **Explanation**          | Every `field/2` call expands a `quote` block that validates the field name, checks the type against an allowlist, validates constraint options (`:required`, `:min`, `:max`, `:format`), accumulates a module attribute, and generates two public functions (`validate_FIELD/1` and `cast_FIELD/1`) each containing `cond`/`case` logic. A typical user-management form may declare 10–15 fields; all this code is expanded and compiled independently for each one. The validation and casting logic should live in a plain function, not be inlined into every macro expansion. |

---

```elixir
defmodule MyApp.Forms.Schema do
  @moduledoc """
  DSL for declaring typed, validated form fields.

  Each `field/2` call defines a named input field with its expected type and
  validation constraints. Calling modules receive per-field `validate_*/1`
  and `cast_*/1` functions automatically.

  ## Usage

      defmodule MyApp.Forms.UserRegistrationForm do
        use MyApp.Forms.Schema

        field :email,      :string,  required: true,  format: ~r/@/
        field :username,   :string,  required: true,  min: 3, max: 32
        field :age,        :integer, required: false, min: 18, max: 120
        field :referral,   :string,  required: false, max: 64
        field :newsletter, :boolean, required: false
      end
  """

  @valid_types [:string, :integer, :float, :boolean, :date, :datetime]

  defmacro __using__(_opts) do
    quote do
      import MyApp.Forms.Schema, only: [field: 2, field: 3]
      Module.register_attribute(__MODULE__, :form_fields, accumulate: true)
      @before_compile MyApp.Forms.Schema
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc "Returns all declared field definitions for this form."
      def __fields__, do: @form_fields

      @doc "Validates and casts a params map against all declared fields."
      def validate(params) when is_map(params) do
        Enum.reduce(@form_fields, {%{}, []}, fn {name, _type, _opts}, {acc, errors} ->
          raw = Map.get(params, to_string(name))

          case apply(__MODULE__, :"validate_#{name}", [raw]) do
            :ok             -> {Map.put(acc, name, apply(__MODULE__, :"cast_#{name}", [raw])), errors}
            {:error, reason} -> {acc, [{name, reason} | errors]}
          end
        end)
      end
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because each field/2 call expands this entire quote block into
  # the calling module. The expansion includes: an atom check on name, a type-membership guard,
  # option extraction (required/min/max/format), individual boundary checks for each option,
  # a module-attribute write, and two complete function definitions — validate_FIELD/1 (with a
  # multi-branch cond) and cast_FIELD/1 (with a case/type dispatch) — each inlining all the
  # option values from the macro call site. A form with 12 fields compiles all of this 12
  # separate times. Delegating to a `__define_field__/4` plain function would cut the compiled
  # footprint dramatically.
  defmacro field(name, type, opts \\ []) do
    quote do
      unless is_atom(unquote(name)) do
        raise ArgumentError,
              "field/2: field name must be an atom, got: #{inspect(unquote(name))}"
      end

      unless unquote(type) in unquote(@valid_types) do
        raise ArgumentError,
              "field/2: unsupported type #{inspect(unquote(type))} for field #{inspect(unquote(name))}. " <>
                "Valid types: #{inspect(unquote(@valid_types))}"
      end

      required = Keyword.get(unquote(opts), :required, false)
      min_val  = Keyword.get(unquote(opts), :min)
      max_val  = Keyword.get(unquote(opts), :max)
      format   = Keyword.get(unquote(opts), :format)

      unless is_boolean(required) do
        raise ArgumentError,
              "field/2 #{inspect(unquote(name))}: :required must be a boolean"
      end

      unless is_nil(min_val) or is_number(min_val) do
        raise ArgumentError,
              "field/2 #{inspect(unquote(name))}: :min must be a number, got: #{inspect(min_val)}"
      end

      unless is_nil(max_val) or is_number(max_val) do
        raise ArgumentError,
              "field/2 #{inspect(unquote(name))}: :max must be a number, got: #{inspect(max_val)}"
      end

      unless is_nil(format) or match?(%Regex{}, format) do
        raise ArgumentError,
              "field/2 #{inspect(unquote(name))}: :format must be a Regex, got: #{inspect(format)}"
      end

      @form_fields {unquote(name), unquote(type), [required: required, min: min_val,
                                                    max: max_val, format: format]}

      def unquote(:"validate_#{name}")(value) do
        cond do
          required and is_nil(value) ->
            {:error, "#{unquote(name)} is required"}

          not is_nil(min_val) and is_number(value) and value < min_val ->
            {:error, "#{unquote(name)} must be at least #{min_val}"}

          not is_nil(max_val) and is_number(value) and value > max_val ->
            {:error, "#{unquote(name)} must be at most #{max_val}"}

          not is_nil(format) and is_binary(value) and not Regex.match?(format, value) ->
            {:error, "#{unquote(name)} has an invalid format"}

          true ->
            :ok
        end
      end

      def unquote(:"cast_#{name}")(value) do
        case unquote(type) do
          :integer -> if is_binary(value), do: String.to_integer(value), else: value
          :float   -> if is_binary(value), do: String.to_float(value), else: value
          :boolean -> value in ["true", "1", true, 1]
          _        -> value
        end
      end
    end
  end
  # VALIDATION: SMELL END

  @doc "Returns all types that can be declared for a form field."
  def valid_types, do: @valid_types
end
```
