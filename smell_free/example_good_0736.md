```elixir
defmodule Form.Changeset do
  @moduledoc """
  A lightweight, schema-free changeset for validating arbitrary maps of
  user-submitted form parameters without an Ecto schema.

  Fields are declared as `{name, type}` pairs. `cast/3` coerces raw string
  values from controller params into typed Elixir terms. Validation helpers
  accumulate errors so callers receive a complete picture of all failures
  before presenting feedback to the user.
  """

  @type field_type :: :string | :integer | :float | :boolean | :date | :datetime

  @type t :: %__MODULE__{
          params: map(),
          data: map(),
          errors: %{atom() => [String.t()]},
          valid?: boolean()
        }

  defstruct [params: %{}, data: %{}, errors: %{}, valid?: true]

  @spec cast(map(), map(), [{atom(), field_type()}]) :: t()
  def cast(params, defaults, fields) when is_map(params) and is_list(fields) do
    {data, errors} =
      Enum.reduce(fields, {defaults, %{}}, fn {name, type}, {acc_data, acc_errors} ->
        raw = Map.get(params, Atom.to_string(name)) || Map.get(params, name)

        case coerce(raw, type) do
          {:ok, value} -> {Map.put(acc_data, name, value), acc_errors}
          {:error, msg} -> {acc_data, Map.put(acc_errors, name, [msg])}
          :absent -> {acc_data, acc_errors}
        end
      end)

    %__MODULE__{params: params, data: data, errors: errors, valid?: errors == %{}}
  end

  @spec validate_required(t(), [atom()]) :: t()
  def validate_required(%__MODULE__{} = cs, fields) when is_list(fields) do
    errors =
      Enum.reduce(fields, cs.errors, fn field, acc ->
        if Map.get(cs.data, field) in [nil, "", []] do
          Map.update(acc, field, ["is required"], &["is required" | &1])
        else
          acc
        end
      end)

    %{cs | errors: errors, valid?: errors == %{}}
  end

  @spec validate_length(t(), atom(), keyword()) :: t()
  def validate_length(%__MODULE__{} = cs, field, opts) do
    value = Map.get(cs.data, field)

    errors =
      cond do
        not is_binary(value) ->
          cs.errors

        (min = Keyword.get(opts, :min)) && String.length(value) < min ->
          Map.update(cs.errors, field, ["must be at least #{min} characters"],
            &["must be at least #{min} characters" | &1])

        (max = Keyword.get(opts, :max)) && String.length(value) > max ->
          Map.update(cs.errors, field, ["must be at most #{max} characters"],
            &["must be at most #{max} characters" | &1])

        true ->
          cs.errors
      end

    %{cs | errors: errors, valid?: errors == %{}}
  end

  @spec validate_inclusion(t(), atom(), [term()]) :: t()
  def validate_inclusion(%__MODULE__{} = cs, field, choices) when is_list(choices) do
    value = Map.get(cs.data, field)

    if value != nil and value not in choices do
      msg = "must be one of #{Enum.map_join(choices, ", ", &inspect/1)}"
      errors = Map.update(cs.errors, field, [msg], &[msg | &1])
      %{cs | errors: errors, valid?: false}
    else
      cs
    end
  end

  @spec validate_format(t(), atom(), Regex.t()) :: t()
  def validate_format(%__MODULE__{} = cs, field, pattern) do
    value = Map.get(cs.data, field)

    if is_binary(value) and not Regex.match?(pattern, value) do
      msg = "has invalid format"
      errors = Map.update(cs.errors, field, [msg], &[msg | &1])
      %{cs | errors: errors, valid?: false}
    else
      cs
    end
  end

  @spec get_field(t(), atom()) :: term()
  def get_field(%__MODULE__{data: data}, field), do: Map.get(data, field)

  @spec apply_changes(t()) :: {:ok, map()} | {:error, t()}
  def apply_changes(%__MODULE__{valid?: true, data: data}), do: {:ok, data}
  def apply_changes(%__MODULE__{valid?: false} = cs), do: {:error, cs}

  defp coerce(nil, _type), do: :absent
  defp coerce("", _type), do: :absent
  defp coerce(v, :string) when is_binary(v), do: {:ok, v}
  defp coerce(v, :integer) when is_integer(v), do: {:ok, v}
  defp coerce(v, :integer) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "must be an integer"}
    end
  end
  defp coerce(v, :boolean) when is_boolean(v), do: {:ok, v}
  defp coerce("true", :boolean), do: {:ok, true}
  defp coerce("false", :boolean), do: {:ok, false}
  defp coerce(_, :boolean), do: {:error, "must be true or false"}
  defp coerce(v, :date) when is_binary(v) do
    case Date.from_iso8601(v) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "must be a valid date (YYYY-MM-DD)"}
    end
  end
  defp coerce(v, _type), do: {:ok, v}
end
```
