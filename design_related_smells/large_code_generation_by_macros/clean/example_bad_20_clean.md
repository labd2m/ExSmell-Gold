```elixir
defmodule MyApp.Billing.InvoiceSchema do
  @moduledoc """
  Provides a small DSL for declaring line-item validation rules on billing
  modules.

  Example usage:

      defmodule MyApp.Billing.ConsultingInvoice do
        use MyApp.Billing.InvoiceSchema

        validates_line_item :hours,       type: :float,   min: 0.0
        validates_line_item :unit_price,  type: :decimal, min: 0
        validates_line_item :discount,    type: :decimal, min: 0, max: 100
        validates_line_item :tax_rate,    type: :decimal, min: 0, max: 1
      end
  """

  defmacro __using__(_opts) do
    quote do
      import MyApp.Billing.InvoiceSchema, only: [validates_line_item: 2]
      Module.register_attribute(__MODULE__, :line_item_rules, accumulate: true)
      @before_compile MyApp.Billing.InvoiceSchema
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def line_item_rules, do: @line_item_rules

      def validate_line_item(item) do
        MyApp.Billing.InvoiceSchema.run_validations(__MODULE__.line_item_rules(), item)
      end
    end
  end

  defmacro validates_line_item(field, opts) do
    quote do
      field = unquote(field)
      opts  = unquote(opts)

      unless is_atom(field) do
        raise ArgumentError,
              "validates_line_item/2: field must be an atom, got #{inspect(field)}"
      end

      allowed_types = [:integer, :float, :decimal, :string, :boolean]
      type = Keyword.get(opts, :type, :string)

      unless type in allowed_types do
        raise ArgumentError,
              "validates_line_item/2: unknown type #{inspect(type)} for field " <>
                "#{inspect(field)}. Allowed: #{inspect(allowed_types)}"
      end

      min_val = Keyword.get(opts, :min)
      max_val = Keyword.get(opts, :max)

      if not is_nil(min_val) and type not in [:integer, :float, :decimal] do
        raise ArgumentError,
              "validates_line_item/2: :min is only valid for numeric types, " <>
                "field #{inspect(field)} has type #{inspect(type)}"
      end

      if not is_nil(max_val) and type not in [:integer, :float, :decimal] do
        raise ArgumentError,
              "validates_line_item/2: :max is only valid for numeric types, " <>
                "field #{inspect(field)} has type #{inspect(type)}"
      end

      if not is_nil(min_val) and not is_nil(max_val) and min_val > max_val do
        raise ArgumentError,
              "validates_line_item/2: :min (#{min_val}) must be <= :max (#{max_val}) " <>
                "for field #{inspect(field)}"
      end

      existing_rules = Module.get_attribute(__MODULE__, :line_item_rules)

      if Enum.any?(existing_rules, fn {f, _} -> f == field end) do
        raise ArgumentError,
              "validates_line_item/2: duplicate rule for field #{inspect(field)} " <>
                "in #{inspect(__MODULE__)}"
      end

      rule = {field, [type: type, min: min_val, max: max_val] ++ Keyword.drop(opts, [:type, :min, :max])}
      @line_item_rules rule
    end
  end

  @doc false
  def run_validations(rules, item) do
    Enum.reduce(rules, {:ok, item}, fn
      _rule, {:error, _} = err ->
        err

      {field, opts}, {:ok, acc} ->
        value = Map.get(acc, field)
        type  = Keyword.fetch!(opts, :type)
        min   = Keyword.get(opts, :min)
        max   = Keyword.get(opts, :max)

        with :ok <- validate_type(field, value, type),
             :ok <- validate_min(field, value, min),
             :ok <- validate_max(field, value, max) do
          {:ok, acc}
        end
    end)
  end

  defp validate_type(_field, _value, :string), do: :ok
  defp validate_type(field, value, type) when type in [:integer, :float, :decimal] do
    if is_number(value), do: :ok, else: {:error, "#{field} must be numeric"}
  end
  defp validate_type(field, value, :boolean) do
    if is_boolean(value), do: :ok, else: {:error, "#{field} must be boolean"}
  end

  defp validate_min(_field, _value, nil), do: :ok
  defp validate_min(field, value, min) when is_number(value) do
    if value >= min, do: :ok, else: {:error, "#{field} must be >= #{min}"}
  end

  defp validate_max(_field, _value, nil), do: :ok
  defp validate_max(field, value, max) when is_number(value) do
    if value <= max, do: :ok, else: {:error, "#{field} must be <= #{max}"}
  end
end
```
