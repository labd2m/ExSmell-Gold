```elixir
defmodule MyApp.DataQuality.RecordValidator do
  @moduledoc """
  Validates imported data records against a set of named quality rules
  before they are written to the primary database. Rules are composable
  functions that receive the record map and return either `:ok` or a
  structured violation. The validator runs all rules and collects every
  violation rather than halting at the first failure, so importers
  receive a complete picture of what needs fixing per record.
  """

  @type record :: map()
  @type rule_name :: atom()
  @type violation :: %{rule: rule_name(), field: String.t() | nil, message: String.t()}
  @type rule_fn :: (record() -> :ok | violation())

  @type validation_result :: %{
          valid: boolean(),
          violations: [violation()]
        }

  @builtin_rules [
    {:non_empty_id, &__MODULE__.rule_non_empty_id/1},
    {:no_null_required_fields, &__MODULE__.rule_no_null_required_fields/1},
    {:email_format, &__MODULE__.rule_email_format/1},
    {:positive_amounts, &__MODULE__.rule_positive_amounts/1},
    {:iso_date_fields, &__MODULE__.rule_iso_date_fields/1}
  ]

  @doc """
  Validates `record` against all built-in rules plus any `extra_rules`
  provided by the caller. Returns a result map with a validity flag and
  the full list of violations.
  """
  @spec validate(record(), [{rule_name(), rule_fn()}]) :: validation_result()
  def validate(record, extra_rules \\ []) when is_map(record) do
    all_rules = @builtin_rules ++ extra_rules

    violations =
      all_rules
      |> Enum.flat_map(fn {_name, rule_fn} ->
        case rule_fn.(record) do
          :ok -> []
          %{} = violation -> [violation]
          violations when is_list(violations) -> violations
        end
      end)

    %{valid: violations == [], violations: violations}
  end

  @doc "Validates a batch of records; returns results in the same order."
  @spec validate_batch([record()], [{rule_name(), rule_fn()}]) :: [validation_result()]
  def validate_batch(records, extra_rules \\ []) when is_list(records) do
    Enum.map(records, &validate(&1, extra_rules))
  end

  @doc "Returns the count of valid and invalid records from a batch result."
  @spec batch_summary([validation_result()]) :: %{valid: non_neg_integer(), invalid: non_neg_integer()}
  def batch_summary(results) when is_list(results) do
    %{
      valid: Enum.count(results, & &1.valid),
      invalid: Enum.count(results, &(not &1.valid))
    }
  end

  @doc false
  @spec rule_non_empty_id(record()) :: :ok | violation()
  def rule_non_empty_id(%{"id" => id}) when is_binary(id) and byte_size(id) > 0, do: :ok

  def rule_non_empty_id(_record),
    do: %{rule: :non_empty_id, field: "id", message: "must be a non-empty string"}

  @doc false
  @spec rule_no_null_required_fields(record()) :: :ok | [violation()]
  def rule_no_null_required_fields(record) do
    required = ["id", "created_at", "type"]

    violations =
      Enum.flat_map(required, fn field ->
        if Map.get(record, field) in [nil, ""],
          do: [%{rule: :no_null_required_fields, field: field, message: "must not be null or empty"}],
          else: []
      end)

    if violations == [], do: :ok, else: violations
  end

  @doc false
  @spec rule_email_format(record()) :: :ok | violation()
  def rule_email_format(%{"email" => email}) when is_binary(email) do
    if String.match?(email, ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/),
      do: :ok,
      else: %{rule: :email_format, field: "email", message: "is not a valid email address"}
  end

  def rule_email_format(_), do: :ok

  @doc false
  @spec rule_positive_amounts(record()) :: :ok | [violation()]
  def rule_positive_amounts(record) do
    amount_fields = ["amount_cents", "price_cents", "total_cents"]

    violations =
      Enum.flat_map(amount_fields, fn field ->
        case Map.get(record, field) do
          nil -> []
          val when is_integer(val) and val >= 0 -> []
          _ -> [%{rule: :positive_amounts, field: field, message: "must be a non-negative integer"}]
        end
      end)

    if violations == [], do: :ok, else: violations
  end

  @doc false
  @spec rule_iso_date_fields(record()) :: :ok | [violation()]
  def rule_iso_date_fields(record) do
    date_fields = Enum.filter(Map.keys(record), &String.ends_with?(&1, "_at"))

    violations =
      Enum.flat_map(date_fields, fn field ->
        case Map.get(record, field) do
          nil -> []
          val when is_binary(val) ->
            case DateTime.from_iso8601(val) do
              {:ok, _, _} -> []
              _ ->
                [%{rule: :iso_date_fields, field: field, message: "must be a valid ISO 8601 datetime"}]
            end
          _ ->
            [%{rule: :iso_date_fields, field: field, message: "must be a string datetime"}]
        end
      end)

    if violations == [], do: :ok, else: violations
  end
end
```
