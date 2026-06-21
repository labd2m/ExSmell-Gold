# File: `example_good_14.md`

```elixir
defmodule Config.Validator do
  @moduledoc """
  Validates structured application configuration maps against a typed
  schema at startup or in tests.

  Each rule is expressed as a declarative field specification, and
  validation produces a detailed list of errors rather than stopping
  at the first failure, so all problems are surfaced at once.
  """

  @type field_name :: atom()
  @type field_type :: :string | :integer | :boolean | :atom | :list | :map

  @type field_spec :: %{
          required(:name) => field_name(),
          required(:type) => field_type(),
          optional(:required) => boolean(),
          optional(:min) => number(),
          optional(:max) => number(),
          optional(:one_of) => [term()],
          optional(:default) => term()
        }

  @type validation_error :: {field_name(), String.t()}
  @type validated_config :: map()

  @doc """
  Validates `config` against the provided `schema`.

  Returns `{:ok, config_with_defaults}` when all required fields are
  present and all values satisfy their type and constraint rules.
  Returns `{:error, errors}` with a list of `{field, message}` pairs
  describing every violation found.
  """
  @spec validate(map(), [field_spec()]) ::
          {:ok, validated_config()} | {:error, [validation_error()]}
  def validate(config, schema) when is_map(config) and is_list(schema) do
    config_with_defaults = apply_defaults(config, schema)

    errors =
      schema
      |> Enum.flat_map(&validate_field(config_with_defaults, &1))

    case errors do
      [] -> {:ok, config_with_defaults}
      _ -> {:error, errors}
    end
  end

  defp apply_defaults(config, schema) do
    Enum.reduce(schema, config, fn spec, acc ->
      if Map.has_key?(spec, :default) and not Map.has_key?(acc, spec.name) do
        Map.put(acc, spec.name, spec.default)
      else
        acc
      end
    end)
  end

  defp validate_field(config, %{name: name} = spec) do
    value = Map.get(config, name)
    required = Map.get(spec, :required, true)

    cond do
      is_nil(value) and required ->
        [{name, "is required but missing"}]

      is_nil(value) ->
        []

      true ->
        run_type_and_constraint_checks(name, value, spec)
    end
  end

  defp run_type_and_constraint_checks(name, value, spec) do
    []
    |> check_type(name, value, spec.type)
    |> check_min(name, value, spec)
    |> check_max(name, value, spec)
    |> check_one_of(name, value, spec)
  end

  defp check_type(errors, name, value, :string) when not is_binary(value) do
    [{name, "must be a string, got #{type_name(value)}"} | errors]
  end

  defp check_type(errors, name, value, :integer) when not is_integer(value) do
    [{name, "must be an integer, got #{type_name(value)}"} | errors]
  end

  defp check_type(errors, name, value, :boolean) when not is_boolean(value) do
    [{name, "must be a boolean, got #{type_name(value)}"} | errors]
  end

  defp check_type(errors, name, value, :atom) when not is_atom(value) do
    [{name, "must be an atom, got #{type_name(value)}"} | errors]
  end

  defp check_type(errors, name, value, :list) when not is_list(value) do
    [{name, "must be a list, got #{type_name(value)}"} | errors]
  end

  defp check_type(errors, name, value, :map) when not is_map(value) do
    [{name, "must be a map, got #{type_name(value)}"} | errors]
  end

  defp check_type(errors, _name, _value, _type), do: errors

  defp check_min(errors, name, value, %{min: min}) when is_number(value) and value < min do
    [{name, "must be at least #{min}"} | errors]
  end

  defp check_min(errors, name, value, %{min: min}) when is_binary(value) and byte_size(value) < min do
    [{name, "must be at least #{min} characters"} | errors]
  end

  defp check_min(errors, _name, _value, _spec), do: errors

  defp check_max(errors, name, value, %{max: max}) when is_number(value) and value > max do
    [{name, "must be at most #{max}"} | errors]
  end

  defp check_max(errors, name, value, %{max: max}) when is_binary(value) and byte_size(value) > max do
    [{name, "must be at most #{max} characters"} | errors]
  end

  defp check_max(errors, _name, _value, _spec), do: errors

  defp check_one_of(errors, name, value, %{one_of: allowed}) do
    if value in allowed do
      errors
    else
      [{name, "must be one of #{inspect(allowed)}, got #{inspect(value)}"} | errors]
    end
  end

  defp check_one_of(errors, _name, _value, _spec), do: errors

  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_float(value), do: "float"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(value) when is_atom(value), do: "atom"
  defp type_name(value) when is_list(value), do: "list"
  defp type_name(value) when is_map(value), do: "map"
  defp type_name(_value), do: "unknown"
end
```
