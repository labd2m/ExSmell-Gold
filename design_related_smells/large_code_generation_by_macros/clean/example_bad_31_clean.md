```elixir
defmodule MyApp.Validation.SchemaDSL do
  @moduledoc """
  DSL for declaring validation rules on a schema module.

  Example:

      defmodule MyApp.Schemas.CustomerSchema do
        use MyApp.Validation.SchemaDSL

        validates :name,         type: :string, required: true, min_length: 2, max_length: 100
        validates :email,        type: :string, required: true, format: ~r/@/
        validates :age,          type: :integer, min: 18, max: 120
        validates :country_code, type: :string, length: 2, allowed: ~w[BR US DE FR]
        validates :status,       type: :atom, allowed: [:active, :inactive, :pending]
      end
  """

  defmacro __using__(_opts) do
    quote do
      import MyApp.Validation.SchemaDSL, only: [validates: 2]
      Module.register_attribute(__MODULE__, :validation_rules, accumulate: true)
      @before_compile MyApp.Validation.SchemaDSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def validation_rules, do: @validation_rules

      def validate(data) do
        MyApp.Validation.SchemaDSL.run_validation(__MODULE__.validation_rules(), data)
      end
    end
  end

  defmacro validates(field, opts) do
    quote do
      field = unquote(field)
      opts  = unquote(opts)

      unless is_atom(field) do
        raise ArgumentError,
              "validates/2: field must be an atom, got #{inspect(field)}"
      end

      valid_types = [:string, :integer, :float, :boolean, :atom, :list, :map, :date, :datetime]
      type = Keyword.get(opts, :type, :string)

      unless type in valid_types do
        raise ArgumentError,
              "validates/2: :type must be one of #{inspect(valid_types)}, got #{inspect(type)}"
      end

      required = Keyword.get(opts, :required, false)

      unless is_boolean(required) do
        raise ArgumentError,
              "validates/2: :required must be a boolean, got #{inspect(required)}"
      end

      format = Keyword.get(opts, :format)

      if not is_nil(format) do
        unless Regex.regex?(format) do
          raise ArgumentError,
                "validates/2: :format must be a compiled regex, got #{inspect(format)}"
        end

        unless type == :string do
          raise ArgumentError,
                "validates/2: :format is only applicable to :string fields"
        end
      end

      min_length = Keyword.get(opts, :min_length)
      max_length = Keyword.get(opts, :max_length)
      exact_length = Keyword.get(opts, :length)

      if not is_nil(min_length) and (not is_integer(min_length) or min_length < 0) do
        raise ArgumentError,
              "validates/2: :min_length must be a non-negative integer, got #{inspect(min_length)}"
      end

      if not is_nil(max_length) and (not is_integer(max_length) or max_length < 0) do
        raise ArgumentError,
              "validates/2: :max_length must be a non-negative integer, got #{inspect(max_length)}"
      end

      if not is_nil(min_length) and not is_nil(max_length) and min_length > max_length do
        raise ArgumentError,
              "validates/2: :min_length must be <= :max_length for field #{inspect(field)}"
      end

      allowed = Keyword.get(opts, :allowed)

      if not is_nil(allowed) and not is_list(allowed) do
        raise ArgumentError,
              "validates/2: :allowed must be a list, got #{inspect(allowed)}"
      end

      existing = Module.get_attribute(__MODULE__, :validation_rules)

      if Enum.any?(existing, fn r -> r.field == field end) do
        raise ArgumentError,
              "validates/2: duplicate rule for field #{inspect(field)} in #{inspect(__MODULE__)}"
      end

      rule = %{
        field:        field,
        type:         type,
        required:     required,
        format:       format,
        min_length:   min_length,
        max_length:   max_length,
        exact_length: exact_length,
        allowed:      allowed,
        min:          Keyword.get(opts, :min),
        max:          Keyword.get(opts, :max)
      }

      @validation_rules rule
    end
  end

  @doc false
  def run_validation(rules, data) do
    Enum.reduce(rules, {:ok, data}, fn
      _rule, {:error, _} = err -> err
      rule, {:ok, acc}         -> apply_rule(rule, acc)
    end)
  end

  defp apply_rule(%{field: field, required: true} = rule, data) do
    if Map.get(data, field) in [nil, ""] do
      {:error, "#{field} is required"}
    else
      apply_type_checks(rule, data)
    end
  end

  defp apply_rule(rule, data), do: apply_type_checks(rule, data)

  defp apply_type_checks(%{field: field, allowed: allowed} = _rule, data)
       when is_list(allowed) do
    value = Map.get(data, field)

    if is_nil(value) or value in allowed do
      {:ok, data}
    else
      {:error, "#{field} must be one of #{inspect(allowed)}"}
    end
  end

  defp apply_type_checks(_rule, data), do: {:ok, data}
end
```
