```elixir
defmodule Validation.SchemaGuard do
  @moduledoc """
  Validates arbitrary maps against a declarative schema at runtime.
  Schemas are plain maps describing field types, constraints, and
  default values. The guard collects all violations and returns them
  as a structured list so callers can surface complete feedback in a
  single pass rather than discovering errors one at a time.
  """

  @type field_type :: :string | :integer | :float | :boolean | :list | :map | :atom
  @type constraint ::
          {:min, number()} | {:max, number()} | {:min_length, non_neg_integer()}
          | {:max_length, non_neg_integer()} | {:one_of, [term()]} | {:regex, Regex.t()}
  @type field_schema :: %{
          type: field_type(),
          required: boolean(),
          default: term(),
          constraints: [constraint()]
        }
  @type schema :: %{atom() => field_schema()}
  @type field_error :: %{field: atom(), reason: atom(), detail: String.t()}
  @type guard_result :: {:ok, map()} | {:error, [field_error()]}

  @doc """
  Validates and coerces `input` against `schema`. Returns the coerced map
  with defaults applied, or a list of per-field errors.
  """
  @spec validate(map(), schema()) :: guard_result()
  def validate(input, schema) when is_map(input) and is_map(schema) do
    {coerced, errors} =
      Enum.reduce(schema, {%{}, []}, fn {field, spec}, {acc, errs} ->
        raw = Map.get(input, field, Map.get(input, Atom.to_string(field)))
        check_field(field, spec, raw, acc, errs)
      end)

    if Enum.empty?(errors), do: {:ok, coerced}, else: {:error, Enum.reverse(errors)}
  end

  defp check_field(field, %{required: true, default: nil}, nil, acc, errs) do
    error = %{field: field, reason: :required, detail: "#{field} is required"}
    {acc, [error | errs]}
  end

  defp check_field(field, %{default: default}, nil, acc, errs) when not is_nil(default) do
    {Map.put(acc, field, default), errs}
  end

  defp check_field(_field, _spec, nil, acc, errs), do: {acc, errs}

  defp check_field(field, %{type: type, constraints: constraints}, raw, acc, errs) do
    case coerce_type(type, raw) do
      {:ok, value} ->
        constraint_errors = check_constraints(field, value, constraints)
        if Enum.empty?(constraint_errors) do
          {Map.put(acc, field, value), errs}
        else
          {acc, constraint_errors ++ errs}
        end

      :error ->
        error = %{field: field, reason: :type_mismatch, detail: "#{field} must be #{type}"}
        {acc, [error | errs]}
    end
  end

  defp coerce_type(:string, v) when is_binary(v), do: {:ok, v}
  defp coerce_type(:integer, v) when is_integer(v), do: {:ok, v}
  defp coerce_type(:integer, v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end
  defp coerce_type(:float, v) when is_float(v), do: {:ok, v}
  defp coerce_type(:float, v) when is_integer(v), do: {:ok, v * 1.0}
  defp coerce_type(:boolean, v) when is_boolean(v), do: {:ok, v}
  defp coerce_type(:list, v) when is_list(v), do: {:ok, v}
  defp coerce_type(:map, v) when is_map(v), do: {:ok, v}
  defp coerce_type(:atom, v) when is_atom(v), do: {:ok, v}
  defp coerce_type(_, _), do: :error

  defp check_constraints(field, value, constraints) do
    Enum.flat_map(constraints, fn constraint ->
      case apply_constraint(constraint, value) do
        :ok -> []
        {:error, reason, detail} -> [%{field: field, reason: reason, detail: detail}]
      end
    end)
  end

  defp apply_constraint({:min, min}, v) when is_number(v) and v >= min, do: :ok
  defp apply_constraint({:min, min}, _v), do: {:error, :below_min, "must be >= #{min}"}
  defp apply_constraint({:max, max}, v) when is_number(v) and v <= max, do: :ok
  defp apply_constraint({:max, max}, _v), do: {:error, :above_max, "must be <= #{max}"}
  defp apply_constraint({:min_length, min}, v) when is_binary(v) and byte_size(v) >= min, do: :ok
  defp apply_constraint({:min_length, min}, _v), do: {:error, :too_short, "must be at least #{min} chars"}
  defp apply_constraint({:max_length, max}, v) when is_binary(v) and byte_size(v) <= max, do: :ok
  defp apply_constraint({:max_length, max}, _v), do: {:error, :too_long, "must be at most #{max} chars"}
  defp apply_constraint({:one_of, choices}, v) do
    if v in choices, do: :ok, else: {:error, :invalid_choice, "must be one of #{inspect(choices)}"}
  end
  defp apply_constraint({:regex, pattern}, v) when is_binary(v) do
    if String.match?(v, pattern), do: :ok, else: {:error, :pattern_mismatch, "does not match required pattern"}
  end
  defp apply_constraint(_, _), do: :ok
end
```
