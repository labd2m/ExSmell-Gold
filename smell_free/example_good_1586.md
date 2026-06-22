```elixir
defmodule Anonymizer.Rule do
  @moduledoc """
  Describes a single field anonymization rule including its strategy.
  """

  @type strategy ::
          :redact
          | :hash
          | :mask_email
          | :mask_phone
          | :truncate_date
          | {:replace, String.t()}

  @type t :: %__MODULE__{field: atom(), strategy: strategy()}
  defstruct [:field, :strategy]
end

defmodule Anonymizer do
  alias Anonymizer.Rule

  @moduledoc """
  Applies a configured set of anonymization rules to map-based records.
  Useful for GDPR right-to-erasure pipelines and test data preparation.
  Unspecified fields are passed through without modification.
  """

  @type ruleset :: [Rule.t()]

  @spec anonymize(map(), ruleset()) :: {:ok, map()} | {:error, term()}
  def anonymize(record, rules) when is_map(record) and is_list(rules) do
    result =
      Enum.reduce_while(rules, record, fn rule, acc ->
        case apply_rule(acc, rule) do
          {:ok, updated} -> {:cont, updated}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:error, _} = error -> error
      updated_record -> {:ok, updated_record}
    end
  end

  @spec anonymize_batch([map()], ruleset()) :: {:ok, [map()]} | {:error, term()}
  def anonymize_batch(records, rules) when is_list(records) do
    results =
      Enum.reduce_while(records, [], fn record, acc ->
        case anonymize(record, rules) do
          {:ok, anon} -> {:cont, acc ++ [anon]}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case results do
      {:error, _} = error -> error
      list -> {:ok, list}
    end
  end

  defp apply_rule(record, %Rule{field: field, strategy: :redact}) do
    {:ok, Map.put(record, field, nil)}
  end

  defp apply_rule(record, %Rule{field: field, strategy: :hash}) do
    case Map.fetch(record, field) do
      {:ok, value} when is_binary(value) ->
        hashed = :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
        {:ok, Map.put(record, field, hashed)}

      {:ok, _} ->
        {:error, {:unhashable_field, field}}

      :error ->
        {:ok, record}
    end
  end

  defp apply_rule(record, %Rule{field: field, strategy: :mask_email}) do
    case Map.fetch(record, field) do
      {:ok, email} when is_binary(email) ->
        masked = mask_email(email)
        {:ok, Map.put(record, field, masked)}

      _ ->
        {:ok, record}
    end
  end

  defp apply_rule(record, %Rule{field: field, strategy: :mask_phone}) do
    case Map.fetch(record, field) do
      {:ok, phone} when is_binary(phone) ->
        masked = String.replace(phone, ~r/\d(?=\d{4})/, "*")
        {:ok, Map.put(record, field, masked)}

      _ ->
        {:ok, record}
    end
  end

  defp apply_rule(record, %Rule{field: field, strategy: :truncate_date}) do
    case Map.fetch(record, field) do
      {:ok, %Date{year: y}} -> {:ok, Map.put(record, field, Date.new!(y, 1, 1))}
      _ -> {:ok, record}
    end
  end

  defp apply_rule(record, %Rule{field: field, strategy: {:replace, value}}) do
    {:ok, Map.put(record, field, value)}
  end

  defp mask_email(email) do
    case String.split(email, "@") do
      [local, domain] ->
        masked_local = String.slice(local, 0, 2) <> String.duplicate("*", max(String.length(local) - 2, 0))
        "#{masked_local}@#{domain}"

      _ ->
        "***@***.***"
    end
  end
end
```
