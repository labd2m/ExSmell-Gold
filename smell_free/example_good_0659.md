```elixir
defmodule MyApp.Workflows.FormBuilder do
  @moduledoc """
  Constructs dynamic form schemas from a persisted field definition list
  and produces Ecto-compatible changesets for validating user submissions.
  Each field type maps to a discrete validation strategy, keeping type
  handling exhaustive and the main validation loop simple.

  Form definitions are fetched once and cached; submissions call
  `validate/2` directly without another database round-trip.
  """

  alias MyApp.Repo
  alias MyApp.Workflows.FormDefinition

  @type field_type :: :text | :email | :integer | :select | :boolean | :date
  @type field_def :: %{
          required(:name) => String.t(),
          required(:type) => field_type(),
          required(:required) => boolean(),
          optional(:options) => [String.t()],
          optional(:min) => number(),
          optional(:max) => number()
        }
  @type submission :: %{String.t() => term()}
  @type validation_errors :: %{String.t() => [String.t()]}

  @doc """
  Validates `submission` against the field definitions for `form_id`.
  Returns `{:ok, coerced}` on success or `{:error, errors}`.
  """
  @spec validate(String.t(), submission()) ::
          {:ok, map()} | {:error, validation_errors()} | {:error, :form_not_found}
  def validate(form_id, submission) when is_binary(form_id) and is_map(submission) do
    case fetch_definition(form_id) do
      nil ->
        {:error, :form_not_found}

      %FormDefinition{fields: fields} ->
        run_validation(fields, submission)
    end
  end

  @spec run_validation([field_def()], submission()) ::
          {:ok, map()} | {:error, validation_errors()}
  defp run_validation(fields, submission) do
    {coerced, errors} =
      Enum.reduce(fields, {%{}, %{}}, fn field, {ok_acc, err_acc} ->
        raw = Map.get(submission, field.name)

        case validate_field(field, raw) do
          {:ok, nil} -> {ok_acc, err_acc}
          {:ok, value} -> {Map.put(ok_acc, field.name, value), err_acc}
          {:error, msgs} -> {ok_acc, Map.put(err_acc, field.name, msgs)}
        end
      end)

    if map_size(errors) == 0, do: {:ok, coerced}, else: {:error, errors}
  end

  @spec validate_field(field_def(), term()) :: {:ok, term() | nil} | {:error, [String.t()]}
  defp validate_field(%{required: true}, nil), do: {:error, ["is required"]}
  defp validate_field(%{required: false}, nil), do: {:ok, nil}

  defp validate_field(%{type: :text, max: max}, val) when is_binary(val) do
    if is_integer(max) and String.length(val) > max,
      do: {:error, ["must be at most #{max} characters"]},
      else: {:ok, val}
  end

  defp validate_field(%{type: :email}, val) when is_binary(val) do
    if String.match?(val, ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/),
      do: {:ok, String.downcase(val)},
      else: {:error, ["is not a valid email address"]}
  end

  defp validate_field(%{type: :integer, min: min, max: max}, val) do
    case parse_integer(val) do
      {:ok, n} ->
        errors = range_errors(n, min, max)
        if errors == [], do: {:ok, n}, else: {:error, errors}

      :error ->
        {:error, ["must be an integer"]}
    end
  end

  defp validate_field(%{type: :select, options: options}, val) when is_binary(val) do
    if val in options,
      do: {:ok, val},
      else: {:error, ["must be one of: #{Enum.join(options, ", ")}"]}
  end

  defp validate_field(%{type: :boolean}, val) when is_boolean(val), do: {:ok, val}
  defp validate_field(%{type: :boolean}, "true"), do: {:ok, true}
  defp validate_field(%{type: :boolean}, "false"), do: {:ok, false}
  defp validate_field(%{type: :boolean}, _), do: {:error, ["must be true or false"]}

  defp validate_field(%{type: :date}, val) when is_binary(val) do
    case Date.from_iso8601(val) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, ["must be a valid date (YYYY-MM-DD)"]}
    end
  end

  defp validate_field(_field, _val), do: {:error, ["is invalid"]}

  @spec parse_integer(term()) :: {:ok, integer()} | :error
  defp parse_integer(n) when is_integer(n), do: {:ok, n}

  defp parse_integer(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_integer(_), do: :error

  @spec range_errors(integer(), number() | nil, number() | nil) :: [String.t()]
  defp range_errors(n, min, max) do
    []
    |> then(fn e -> if is_number(min) and n < min, do: ["must be at least #{min}" | e], else: e end)
    |> then(fn e -> if is_number(max) and n > max, do: ["must be at most #{max}" | e], else: e end)
  end

  @spec fetch_definition(String.t()) :: FormDefinition.t() | nil
  defp fetch_definition(form_id) do
    MyApp.Cache.fetch_or_store(
      {:form_definition, form_id},
      fn -> Repo.get(FormDefinition, form_id) end,
      60_000
    )
    |> case do
      {:ok, result} -> result
    end
  end
end
```
