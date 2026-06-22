```elixir
defmodule Schematic.Schema do
  @moduledoc """
  Composable, pure-function schema validation without macros.
  Schemas are plain data structures (maps of field specs) and
  can be composed, extended, or reused without code generation.
  """

  @type field_spec :: %{
          type: :string | :integer | :float | :boolean | :atom | :map | :list,
          required: boolean(),
          min: number() | nil,
          max: number() | nil,
          one_of: [term()] | nil,
          nested: schema() | nil
        }

  @type schema :: %{atom() => field_spec()}
  @type input :: map()
  @type validation_error :: %{field: atom(), message: String.t()}
  @type result :: {:ok, map()} | {:error, [validation_error()]}

  @spec validate(input(), schema()) :: result()
  def validate(input, schema) when is_map(input) and is_map(schema) do
    errors =
      schema
      |> Enum.flat_map(fn {field, spec} ->
        value = Map.get(input, field) || Map.get(input, Atom.to_string(field))
        validate_field(field, value, spec)
      end)

    if Enum.empty?(errors) do
      {:ok, coerce(input, schema)}
    else
      {:error, errors}
    end
  end

  @spec validate_field(atom(), term(), field_spec()) :: [validation_error()]
  defp validate_field(field, nil, %{required: true}) do
    [%{field: field, message: "is required"}]
  end

  defp validate_field(_field, nil, _spec), do: []

  defp validate_field(field, value, spec) do
    [
      check_type(field, value, spec.type),
      check_min(field, value, spec[:min]),
      check_max(field, value, spec[:max]),
      check_one_of(field, value, spec[:one_of]),
      check_nested(field, value, spec[:nested], spec.type)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  @spec check_type(atom(), term(), atom()) :: validation_error() | nil
  defp check_type(_field, value, :string) when is_binary(value), do: nil
  defp check_type(_field, value, :integer) when is_integer(value), do: nil
  defp check_type(_field, value, :float) when is_float(value), do: nil
  defp check_type(_field, value, :boolean) when is_boolean(value), do: nil
  defp check_type(_field, value, :atom) when is_atom(value), do: nil
  defp check_type(_field, value, :map) when is_map(value), do: nil
  defp check_type(_field, value, :list) when is_list(value), do: nil
  defp check_type(field, _value, expected), do: %{field: field, message: "must be a #{expected}"}

  @spec check_min(atom(), term(), number() | nil) :: validation_error() | nil
  defp check_min(_field, _value, nil), do: nil
  defp check_min(field, value, min) when is_binary(value) and String.length(value) < min do
    %{field: field, message: "must be at least #{min} characters"}
  end

  defp check_min(field, value, min) when is_number(value) and value < min do
    %{field: field, message: "must be at least #{min}"}
  end

  defp check_min(_field, _value, _min), do: nil

  @spec check_max(atom(), term(), number() | nil) :: validation_error() | nil
  defp check_max(_field, _value, nil), do: nil
  defp check_max(field, value, max) when is_binary(value) and String.length(value) > max do
    %{field: field, message: "must be at most #{max} characters"}
  end

  defp check_max(field, value, max) when is_number(value) and value > max do
    %{field: field, message: "must be at most #{max}"}
  end

  defp check_max(_field, _value, _max), do: nil

  @spec check_one_of(atom(), term(), [term()] | nil) :: validation_error() | nil
  defp check_one_of(_field, _value, nil), do: nil

  defp check_one_of(field, value, allowed) do
    unless value in allowed do
      %{field: field, message: "must be one of: #{Enum.join(allowed, ", ")}"}
    end
  end

  @spec check_nested(atom(), term(), schema() | nil, atom()) :: [validation_error()]
  defp check_nested(_field, _value, nil, _type), do: []
  defp check_nested(_field, value, _nested, _type) when not is_map(value), do: []

  defp check_nested(field, value, nested_schema, :map) do
    case validate(value, nested_schema) do
      {:ok, _} ->
        []

      {:error, errors} ->
        Enum.map(errors, fn err ->
          %{err | field: :"#{field}.#{err.field}"}
        end)
    end
  end

  defp check_nested(_field, _value, _nested, _type), do: []

  @spec coerce(input(), schema()) :: map()
  defp coerce(input, schema) do
    Map.new(schema, fn {field, _spec} ->
      value = Map.get(input, field) || Map.get(input, Atom.to_string(field))
      {field, value}
    end)
  end

  @spec field(atom(), keyword()) :: field_spec()
  def field(type, opts \\ []) when is_atom(type) do
    %{
      type: type,
      required: Keyword.get(opts, :required, false),
      min: Keyword.get(opts, :min),
      max: Keyword.get(opts, :max),
      one_of: Keyword.get(opts, :one_of),
      nested: Keyword.get(opts, :nested)
    }
  end

  @spec merge(schema(), schema()) :: schema()
  def merge(base, overrides) when is_map(base) and is_map(overrides) do
    Map.merge(base, overrides)
  end
end
```
