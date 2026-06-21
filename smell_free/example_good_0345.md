```elixir
defmodule Platform.SchemaValidator do
  @moduledoc """
  A lightweight, pure-function schema validator for maps and event payloads.

  Schemas are plain Elixir maps describing expected field types and constraints.
  No external dependencies or macro DSLs are required. Validation is fully
  composable and returns structured error lists rather than raising.
  """

  @type field_type :: :string | :integer | :float | :boolean | :map | :list | :datetime | :date
  @type constraint :: {:required, boolean()} | {:min, number()} | {:max, number()} | {:min_length, non_neg_integer()} | {:max_length, pos_integer()} | {:one_of, [term()]}
  @type field_schema :: %{type: field_type(), constraints: [constraint()]}
  @type schema :: %{optional(atom()) => field_schema()}
  @type validation_error :: %{field: atom(), message: String.t()}
  @type result :: :ok | {:error, [validation_error()]}

  @doc """
  Validates `data` against `schema`. Returns `:ok` or `{:error, errors}`.
  """
  @spec validate(map(), schema()) :: result()
  def validate(data, schema) when is_map(data) and is_map(schema) do
    errors =
      schema
      |> Enum.flat_map(fn {field, field_schema} -> validate_field(data, field, field_schema) end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp validate_field(data, field, %{type: type, constraints: constraints}) do
    value = Map.get(data, field)

    presence_errors = check_required(field, value, constraints)

    if value == nil do
      presence_errors
    else
      type_errors = check_type(field, value, type)
      constraint_errors = if type_errors == [], do: check_constraints(field, value, constraints), else: []
      presence_errors ++ type_errors ++ constraint_errors
    end
  end

  defp check_required(field, nil, constraints) do
    if Keyword.get(constraints, :required, false) do
      [error(field, "is required")]
    else
      []
    end
  end

  defp check_required(_field, _value, _constraints), do: []

  defp check_type(field, value, :string) when not is_binary(value), do: [error(field, "must be a string")]
  defp check_type(field, value, :integer) when not is_integer(value), do: [error(field, "must be an integer")]
  defp check_type(field, value, :float) when not is_float(value) and not is_integer(value), do: [error(field, "must be a number")]
  defp check_type(field, value, :boolean) when not is_boolean(value), do: [error(field, "must be a boolean")]
  defp check_type(field, value, :map) when not is_map(value), do: [error(field, "must be a map")]
  defp check_type(field, value, :list) when not is_list(value), do: [error(field, "must be a list")]
  defp check_type(_field, _value, _type), do: []

  defp check_constraints(field, value, constraints) do
    Enum.flat_map(constraints, fn
      {:min, min} when is_number(value) and value < min ->
        [error(field, "must be at least #{min}")]

      {:max, max} when is_number(value) and value > max ->
        [error(field, "must be at most #{max}")]

      {:min_length, min} when is_binary(value) and byte_size(value) < min ->
        [error(field, "must be at least #{min} characters")]

      {:max_length, max} when is_binary(value) and byte_size(value) > max ->
        [error(field, "must be at most #{max} characters")]

      {:one_of, choices} ->
        if value in choices, do: [], else: [error(field, "must be one of #{inspect(choices)}")]

      _ ->
        []
    end)
  end

  defp error(field, message), do: %{field: field, message: message}
end
```
