```elixir
defmodule Privacy.AnonymizationRule do
  @moduledoc """
  Describes how a single data field should be anonymized.
  Strategies are pure transformations applied field-by-field.
  """

  @type strategy :: :redact | :hash | :mask_email | :mask_phone | :generalize_age | :drop

  @enforce_keys [:field, :strategy]
  defstruct [:field, :strategy, :salt]

  @type t :: %__MODULE__{field: atom(), strategy: strategy(), salt: String.t() | nil}

  @spec new(atom(), strategy(), keyword()) :: t()
  def new(field, strategy, opts \\ []) when is_atom(field) and is_atom(strategy) do
    %__MODULE__{field: field, strategy: strategy, salt: Keyword.get(opts, :salt)}
  end
end

defmodule Privacy.Anonymizer do
  @moduledoc """
  Applies a set of `Privacy.AnonymizationRule` definitions to a map of
  personal data, returning a new map with all sensitive fields transformed.
  The original map is never mutated.
  """

  alias Privacy.AnonymizationRule

  @type record :: map()
  @type result :: %{anonymized: record(), dropped_fields: list(atom())}

  @spec anonymize(record(), list(AnonymizationRule.t())) :: result()
  def anonymize(record, rules) when is_map(record) and is_list(rules) do
    {transformed, dropped} =
      Enum.reduce(rules, {record, []}, fn rule, {rec, dropped} ->
        apply_rule(rule, rec, dropped)
      end)

    %{anonymized: transformed, dropped_fields: Enum.reverse(dropped)}
  end

  @spec anonymize_batch(list(record()), list(AnonymizationRule.t())) :: list(result())
  def anonymize_batch(records, rules) when is_list(records) and is_list(rules) do
    Enum.map(records, &anonymize(&1, rules))
  end

  defp apply_rule(%AnonymizationRule{field: field, strategy: :drop}, record, dropped) do
    {Map.delete(record, field), [field | dropped]}
  end

  defp apply_rule(%AnonymizationRule{field: field, strategy: strategy} = rule, record, dropped) do
    value = Map.get(record, field)
    transformed = transform(strategy, value, rule.salt)
    {Map.put(record, field, transformed), dropped}
  end

  defp transform(:redact, _value, _salt), do: "[REDACTED]"

  defp transform(:hash, value, salt) when is_binary(value) do
    salted = "#{salt || ""}#{value}"
    :crypto.hash(:sha256, salted) |> Base.url_encode64(padding: false)
  end

  defp transform(:hash, value, salt), do: transform(:hash, inspect(value), salt)

  defp transform(:mask_email, value, _salt) when is_binary(value) do
    case String.split(value, "@") do
      [local, domain] ->
        masked_local = String.slice(local, 0, 2) <> String.duplicate("*", max(0, String.length(local) - 2))
        "#{masked_local}@#{domain}"
      _ -> "[INVALID_EMAIL]"
    end
  end

  defp transform(:mask_phone, value, _salt) when is_binary(value) do
    digits = String.replace(value, ~r/\D/, "")
    len = String.length(digits)
    if len >= 4 do
      String.duplicate("*", len - 4) <> String.slice(digits, -4, 4)
    else
      String.duplicate("*", len)
    end
  end

  defp transform(:generalize_age, value, _salt) when is_integer(value) do
    bucket_start = div(value, 10) * 10
    "#{bucket_start}-#{bucket_start + 9}"
  end

  defp transform(_strategy, nil, _salt), do: nil
  defp transform(_strategy, value, _salt), do: value
end

defmodule Privacy.Pipeline do
  @moduledoc """
  Wraps anonymization with audit logging so every transformation is traceable.
  """

  require Logger

  alias Privacy.{Anonymizer, AnonymizationRule}

  @spec run(list(map()), list(AnonymizationRule.t()), String.t()) ::
          {:ok, list(map())} | {:error, :empty_ruleset}
  def run(_records, [], _pipeline_id), do: {:error, :empty_ruleset}

  def run(records, rules, pipeline_id) when is_list(records) and is_list(rules) and is_binary(pipeline_id) do
    Logger.info("Anonymization pipeline started", pipeline_id: pipeline_id, record_count: length(records))

    results = Anonymizer.anonymize_batch(records, rules)

    total_dropped = results |> Enum.flat_map(& &1.dropped_fields) |> length()

    Logger.info("Anonymization pipeline complete",
      pipeline_id: pipeline_id,
      record_count: length(results),
      total_dropped_fields: total_dropped
    )

    {:ok, Enum.map(results, & &1.anonymized)}
  end
end
```
