```elixir
defmodule Schema.Rule do
  @moduledoc false

  @type t ::
          {:type, atom()}
          | {:required, [String.t()]}
          | {:min_length, pos_integer()}
          | {:max_length, pos_integer()}
          | {:minimum, number()}
          | {:maximum, number()}
          | {:enum, [term()]}
          | {:pattern, Regex.t()}
          | {:properties, %{String.t() => [Schema.Rule.t()]}}
          | {:items, [Schema.Rule.t()]}
end

defmodule Schema.Validator do
  @moduledoc """
  Validates maps and lists against a declarative rule set, collecting all
  constraint violations before returning rather than halting on the first
  error.

  Rules are plain tuples that compose without any macro magic. A
  `{:properties, %{}}` rule recursively validates nested maps, and
  `{:items, rules}` applies rules to every element of a list. Paths
  in error messages use dot-notation for readability.
  """

  alias Schema.Rule

  @type path :: String.t()
  @type error :: {path(), String.t()}

  @spec validate(term(), [Rule.t()]) :: :ok | {:error, [error()]}
  def validate(value, rules) when is_list(rules) do
    errors = check_rules(value, rules, "")

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp check_rules(value, rules, path) do
    Enum.flat_map(rules, &check_rule(value, &1, path))
  end

  defp check_rule(value, {:type, :string}, path) do
    if is_binary(value), do: [], else: [{path, "must be a string"}]
  end

  defp check_rule(value, {:type, :integer}, path) do
    if is_integer(value), do: [], else: [{path, "must be an integer"}]
  end

  defp check_rule(value, {:type, :number}, path) do
    if is_number(value), do: [], else: [{path, "must be a number"}]
  end

  defp check_rule(value, {:type, :boolean}, path) do
    if is_boolean(value), do: [], else: [{path, "must be a boolean"}]
  end

  defp check_rule(value, {:type, :object}, path) do
    if is_map(value), do: [], else: [{path, "must be an object"}]
  end

  defp check_rule(value, {:type, :array}, path) do
    if is_list(value), do: [], else: [{path, "must be an array"}]
  end

  defp check_rule(value, {:required, fields}, path) when is_map(value) do
    Enum.flat_map(fields, fn field ->
      key_path = join_path(path, field)
      if Map.has_key?(value, field), do: [], else: [{key_path, "is required"}]
    end)
  end

  defp check_rule(value, {:min_length, min}, path) when is_binary(value) do
    if String.length(value) >= min, do: [], else: [{path, "must be at least #{min} characters"}]
  end

  defp check_rule(value, {:max_length, max}, path) when is_binary(value) do
    if String.length(value) <= max, do: [], else: [{path, "must be at most #{max} characters"}]
  end

  defp check_rule(value, {:minimum, min}, path) when is_number(value) do
    if value >= min, do: [], else: [{path, "must be at least #{min}"}]
  end

  defp check_rule(value, {:maximum, max}, path) when is_number(value) do
    if value <= max, do: [], else: [{path, "must be at most #{max}"}]
  end

  defp check_rule(value, {:enum, choices}, path) do
    if value in choices, do: [], else: [{path, "must be one of #{inspect(choices)}"}]
  end

  defp check_rule(value, {:pattern, regex}, path) when is_binary(value) do
    if Regex.match?(regex, value), do: [], else: [{path, "does not match required pattern"}]
  end

  defp check_rule(value, {:properties, prop_rules}, path) when is_map(value) do
    Enum.flat_map(prop_rules, fn {field, field_rules} ->
      field_value = Map.get(value, field)
      field_path = join_path(path, field)
      if field_value != nil, do: check_rules(field_value, field_rules, field_path), else: []
    end)
  end

  defp check_rule(value, {:items, item_rules}, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, idx} ->
      check_rules(item, item_rules, "#{path}[#{idx}]")
    end)
  end

  defp check_rule(_value, _rule, _path), do: []

  defp join_path("", field), do: field
  defp join_path(path, field), do: "#{path}.#{field}"
end
```
