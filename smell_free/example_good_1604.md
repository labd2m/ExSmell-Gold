```elixir
defmodule Schema.Validator do
  @moduledoc """
  Validates arbitrary maps against a declarative schema specification.
  Supports nested objects, typed arrays, optional fields, and custom
  refinement predicates without external dependencies.
  """

  @type field_type :: :string | :integer | :float | :boolean | :map | :list | :any
  @type field_spec :: %{
          type: field_type(),
          required: boolean(),
          items: field_spec() | nil,
          properties: %{String.t() => field_spec()} | nil,
          validate: (term() -> :ok | {:error, String.t()}) | nil
        }
  @type schema :: %{String.t() => field_spec()}
  @type validation_error :: %{path: String.t(), reason: String.t()}
  @type result :: :ok | {:error, [validation_error()]}

  @spec validate(map(), schema()) :: result()
  def validate(data, schema) when is_map(data) and is_map(schema) do
    errors = collect_errors(data, schema, "")

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  @spec collect_errors(map(), schema(), String.t()) :: [validation_error()]
  defp collect_errors(data, schema, path_prefix) do
    schema
    |> Enum.flat_map(fn {field, spec} ->
      field_path = build_path(path_prefix, field)
      value = Map.get(data, field)
      check_field(field_path, value, spec)
    end)
  end

  @spec check_field(String.t(), term(), field_spec()) :: [validation_error()]
  defp check_field(path, nil, %{required: true}) do
    [%{path: path, reason: "is required"}]
  end

  defp check_field(_path, nil, %{required: false}), do: []
  defp check_field(_path, nil, _spec), do: []

  defp check_field(path, value, spec) do
    type_errors = check_type(path, value, spec.type)

    if type_errors == [] do
      nested_errors = check_nested(path, value, spec)
      refinement_errors = check_refinement(path, value, spec)
      nested_errors ++ refinement_errors
    else
      type_errors
    end
  end

  @spec check_type(String.t(), term(), field_type()) :: [validation_error()]
  defp check_type(_path, _value, :any), do: []
  defp check_type(_path, value, :string) when is_binary(value), do: []
  defp check_type(_path, value, :integer) when is_integer(value), do: []
  defp check_type(_path, value, :float) when is_float(value) or is_integer(value), do: []
  defp check_type(_path, value, :boolean) when is_boolean(value), do: []
  defp check_type(_path, value, :map) when is_map(value), do: []
  defp check_type(_path, value, :list) when is_list(value), do: []

  defp check_type(path, _value, type) do
    [%{path: path, reason: "must be of type #{type}"}]
  end

  @spec check_nested(String.t(), term(), field_spec()) :: [validation_error()]
  defp check_nested(path, value, %{type: :map, properties: props}) when is_map(props) do
    collect_errors(value, props, path)
  end

  defp check_nested(path, values, %{type: :list, items: item_spec}) when not is_nil(item_spec) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, idx} ->
      item_path = "#{path}[#{idx}]"
      check_field(item_path, item, item_spec)
    end)
  end

  defp check_nested(_path, _value, _spec), do: []

  @spec check_refinement(String.t(), term(), field_spec()) :: [validation_error()]
  defp check_refinement(_path, _value, %{validate: nil}), do: []
  defp check_refinement(_path, _value, spec) when not is_map_key(spec, :validate), do: []

  defp check_refinement(path, value, %{validate: fun}) when is_function(fun, 1) do
    case fun.(value) do
      :ok -> []
      {:error, reason} -> [%{path: path, reason: reason}]
    end
  end

  @spec build_path(String.t(), String.t()) :: String.t()
  defp build_path("", field), do: field
  defp build_path(prefix, field), do: "#{prefix}.#{field}"
end
```
