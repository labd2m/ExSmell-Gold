```elixir
defmodule Parsing.JSONSchema do
  @moduledoc """
  Validates and coerces raw decoded JSON maps against a field schema
  definition. Each field declares its type, optionality, and an optional
  default. The validator returns either a typed struct-like map with
  coerced values or a list of per-field errors for the caller to report.
  """

  @type field_type :: :string | :integer | :float | :boolean | :datetime
  @type field_spec :: %{
          type: field_type(),
          required: boolean(),
          default: term() | nil
        }
  @type schema :: %{atom() => field_spec()}
  @type coerced :: %{atom() => term()}
  @type field_error :: %{field: atom(), reason: atom()}
  @type validation_result :: {:ok, coerced()} | {:error, [field_error()]}

  @doc """
  Validates `input` against `schema`. Returns a coerced map on success or
  a list of per-field error descriptors on failure.
  """
  @spec validate(map(), schema()) :: validation_result()
  def validate(input, schema) when is_map(input) and is_map(schema) do
    {coerced, errors} =
      Enum.reduce(schema, {%{}, []}, fn {field, spec}, {acc, errs} ->
        raw = Map.get(input, Atom.to_string(field))
        apply_field(field, spec, raw, acc, errs)
      end)

    if Enum.empty?(errors), do: {:ok, coerced}, else: {:error, Enum.reverse(errors)}
  end

  defp apply_field(field, %{required: true, default: nil}, nil, acc, errs) do
    {acc, [%{field: field, reason: :required_field_missing} | errs]}
  end

  defp apply_field(field, %{default: default}, nil, acc, errs) when default != nil do
    {Map.put(acc, field, default), errs}
  end

  defp apply_field(_field, _spec, nil, acc, errs), do: {acc, errs}

  defp apply_field(field, %{type: type}, raw, acc, errs) do
    case coerce(type, raw) do
      {:ok, value} -> {Map.put(acc, field, value), errs}
      :error -> {acc, [%{field: field, reason: :type_coercion_failed} | errs]}
    end
  end

  defp coerce(:string, v) when is_binary(v), do: {:ok, v}
  defp coerce(:string, v) when is_integer(v), do: {:ok, Integer.to_string(v)}
  defp coerce(:string, _), do: :error

  defp coerce(:integer, v) when is_integer(v), do: {:ok, v}
  defp coerce(:integer, v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end
  defp coerce(:integer, _), do: :error

  defp coerce(:float, v) when is_float(v), do: {:ok, v}
  defp coerce(:float, v) when is_integer(v), do: {:ok, v * 1.0}
  defp coerce(:float, v) when is_binary(v) do
    case Float.parse(v) do
      {f, ""} -> {:ok, f}
      _ -> :error
    end
  end
  defp coerce(:float, _), do: :error

  defp coerce(:boolean, v) when is_boolean(v), do: {:ok, v}
  defp coerce(:boolean, v) when v in ["true", "1", "yes"], do: {:ok, true}
  defp coerce(:boolean, v) when v in ["false", "0", "no"], do: {:ok, false}
  defp coerce(:boolean, _), do: :error

  defp coerce(:datetime, v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end
  defp coerce(:datetime, _), do: :error
end
```
