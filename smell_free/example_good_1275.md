```elixir
defmodule Forms.ValidationPipeline do
  @moduledoc """
  Composable multi-step form validation returning structured error maps.

  Each step is a pure function that receives the accumulated changeset and
  returns a modified version. Steps are run in declaration order and all
  failures are collected before returning, rather than halting at the first error.
  """

  alias Forms.ValidationPipeline.{Changeset, Step}

  @type step_fn :: (Changeset.t() -> Changeset.t())

  @doc """
  Runs a list of validation steps over a raw input map.

  Returns `{:ok, validated_data}` if all steps pass, or
  `{:error, error_map}` where keys are field names and values are error lists.
  """
  @spec run(map(), [step_fn()]) :: {:ok, map()} | {:error, map()}
  def run(raw_input, steps) when is_map(raw_input) and is_list(steps) do
    initial = Changeset.new(raw_input)

    final =
      Enum.reduce(steps, initial, fn step, acc ->
        step.(acc)
      end)

    if Changeset.valid?(final) do
      {:ok, final.data}
    else
      {:error, final.errors}
    end
  end

  @doc """
  Validates that the given fields are present and non-empty.
  """
  @spec require_fields([atom()]) :: step_fn()
  def require_fields(fields) when is_list(fields) do
    fn changeset ->
      Enum.reduce(fields, changeset, fn field, acc ->
        value = Map.get(acc.data, field)

        if present?(value) do
          acc
        else
          Changeset.add_error(acc, field, "is required")
        end
      end)
    end
  end

  @doc """
  Validates that a field value matches a given format regex.
  """
  @spec validate_format(atom(), Regex.t(), String.t()) :: step_fn()
  def validate_format(field, regex, message) do
    fn changeset ->
      value = Map.get(changeset.data, field)

      cond do
        not is_binary(value) -> changeset
        Regex.match?(regex, value) -> changeset
        true -> Changeset.add_error(changeset, field, message)
      end
    end
  end

  @doc """
  Validates that a field's string length is within the given range.
  """
  @spec validate_length(atom(), keyword()) :: step_fn()
  def validate_length(field, opts) do
    min = Keyword.get(opts, :min)
    max = Keyword.get(opts, :max)

    fn changeset ->
      value = Map.get(changeset.data, field)

      if not is_binary(value) do
        changeset
      else
        len = String.length(value)
        changeset
        |> check_min_length(field, len, min)
        |> check_max_length(field, len, max)
      end
    end
  end

  @doc """
  Casts a field to the given type, adding an error if casting fails.
  """
  @spec cast_field(atom(), :integer | :boolean | :date) :: step_fn()
  def cast_field(field, type) do
    fn changeset ->
      raw = Map.get(changeset.data, field)
      cast_value(changeset, field, raw, type)
    end
  end

  defp cast_value(changeset, field, nil, _type), do: changeset

  defp cast_value(changeset, field, raw, :integer) when is_binary(raw) do
    case Integer.parse(raw) do
      {int, ""} -> Changeset.put_data(changeset, field, int)
      _ -> Changeset.add_error(changeset, field, "must be an integer")
    end
  end

  defp cast_value(changeset, field, raw, :date) when is_binary(raw) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> Changeset.put_data(changeset, field, date)
      _ -> Changeset.add_error(changeset, field, "must be a date in YYYY-MM-DD format")
    end
  end

  defp cast_value(changeset, _field, _raw, _type), do: changeset

  defp check_min_length(cs, _field, _len, nil), do: cs
  defp check_min_length(cs, field, len, min) when len < min,
    do: Changeset.add_error(cs, field, "must be at least #{min} characters")
  defp check_min_length(cs, _, _, _), do: cs

  defp check_max_length(cs, _field, _len, nil), do: cs
  defp check_max_length(cs, field, len, max) when len > max,
    do: Changeset.add_error(cs, field, "must be at most #{max} characters")
  defp check_max_length(cs, _, _, _), do: cs

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end

defmodule Forms.ValidationPipeline.Changeset do
  @moduledoc false

  @enforce_keys [:data, :errors]
  defstruct [:data, :errors]

  @type t :: %__MODULE__{data: map(), errors: %{atom() => [String.t()]}}

  @spec new(map()) :: t()
  def new(data) when is_map(data), do: %__MODULE__{data: data, errors: %{}}

  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{errors: errors}), do: errors == %{}

  @spec add_error(t(), atom(), String.t()) :: t()
  def add_error(changeset, field, message) do
    updated = Map.update(changeset.errors, field, [message], &(&1 ++ [message]))
    %{changeset | errors: updated}
  end

  @spec put_data(t(), atom(), term()) :: t()
  def put_data(changeset, field, value) do
    %{changeset | data: Map.put(changeset.data, field, value)}
  end
end
```
