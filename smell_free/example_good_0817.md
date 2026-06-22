# File: `example_good_817.md`

```elixir
defmodule Finance.ExpenseClassifier do
  @moduledoc """
  Classifies expense transactions into categories using an ordered list
  of declarative matching rules.

  Rules are evaluated in priority order; the first matching rule wins.
  Rules can match on merchant name patterns, MCC codes, amount ranges,
  and keyword presence in the transaction description.

  All logic is pure; no I/O occurs. Supply a rule set and a transaction
  map to receive a classification result.
  """

  @type category :: String.t()
  @type mcc_code :: String.t()

  @type transaction :: %{
          required(:amount_cents) => integer(),
          required(:description) => String.t(),
          optional(:merchant_name) => String.t(),
          optional(:mcc_code) => mcc_code()
        }

  @type rule :: %{
          required(:category) => category(),
          required(:priority) => non_neg_integer(),
          optional(:mcc_codes) => [mcc_code()],
          optional(:merchant_pattern) => Regex.t(),
          optional(:description_keywords) => [String.t()],
          optional(:min_amount_cents) => integer(),
          optional(:max_amount_cents) => integer()
        }

  @type classification :: %{
          category: category(),
          confidence: :high | :medium | :low,
          matched_rule_priority: non_neg_integer() | nil,
          fallback: boolean()
        }

  @default_category "Uncategorized"

  @doc """
  Classifies `transaction` against `rules`, returning the category
  from the highest-priority matching rule.

  Rules are sorted by priority (ascending) before evaluation so lower
  priority numbers are checked first. When no rule matches, the
  `:fallback_category` option is used (default: `"Uncategorized"`).
  """
  @spec classify(transaction(), [rule()], keyword()) :: classification()
  def classify(transaction, rules, opts \\ [])
      when is_map(transaction) and is_list(rules) do
    fallback_category = Keyword.get(opts, :fallback_category, @default_category)

    sorted_rules = Enum.sort_by(rules, & &1.priority)

    case Enum.find(sorted_rules, &rule_matches?(&1, transaction)) do
      nil ->
        %{category: fallback_category, confidence: :low, matched_rule_priority: nil, fallback: true}

      rule ->
        confidence = compute_confidence(rule, transaction)
        %{category: rule.category, confidence: confidence,
          matched_rule_priority: rule.priority, fallback: false}
    end
  end

  @doc """
  Classifies a list of transactions in a single pass, returning
  one `classification` per transaction in the same order.
  """
  @spec classify_batch([transaction()], [rule()], keyword()) :: [classification()]
  def classify_batch(transactions, rules, opts \\ []) when is_list(transactions) do
    sorted_rules = Enum.sort_by(rules, & &1.priority)
    fallback_category = Keyword.get(opts, :fallback_category, @default_category)
    Enum.map(transactions, &classify_with_sorted(&1, sorted_rules, fallback_category))
  end

  @doc """
  Returns the subset of `rules` that match `transaction`.

  Useful for debugging why a transaction was classified a certain way.
  """
  @spec matching_rules(transaction(), [rule()]) :: [rule()]
  def matching_rules(transaction, rules) when is_map(transaction) and is_list(rules) do
    rules
    |> Enum.sort_by(& &1.priority)
    |> Enum.filter(&rule_matches?(&1, transaction))
  end

  defp classify_with_sorted(transaction, sorted_rules, fallback_category) do
    case Enum.find(sorted_rules, &rule_matches?(&1, transaction)) do
      nil ->
        %{category: fallback_category, confidence: :low, matched_rule_priority: nil, fallback: true}

      rule ->
        confidence = compute_confidence(rule, transaction)
        %{category: rule.category, confidence: confidence,
          matched_rule_priority: rule.priority, fallback: false}
    end
  end

  defp rule_matches?(rule, transaction) do
    check_mcc(rule, transaction) and
      check_merchant(rule, transaction) and
      check_keywords(rule, transaction) and
      check_amount_range(rule, transaction)
  end

  defp check_mcc(%{mcc_codes: codes}, %{mcc_code: mcc}) when is_list(codes) do
    mcc in codes
  end

  defp check_mcc(%{mcc_codes: _codes}, _transaction), do: false
  defp check_mcc(_rule, _transaction), do: true

  defp check_merchant(%{merchant_pattern: pattern}, transaction) do
    merchant = Map.get(transaction, :merchant_name, "")
    Regex.match?(pattern, merchant)
  end

  defp check_merchant(_rule, _transaction), do: true

  defp check_keywords(%{description_keywords: keywords}, %{description: desc})
       when is_list(keywords) do
    lower_desc = String.downcase(desc)
    Enum.any?(keywords, &String.contains?(lower_desc, String.downcase(&1)))
  end

  defp check_keywords(_rule, _transaction), do: true

  defp check_amount_range(rule, %{amount_cents: amount}) do
    above_min = case Map.get(rule, :min_amount_cents) do
      nil -> true
      min -> amount >= min
    end

    below_max = case Map.get(rule, :max_amount_cents) do
      nil -> true
      max -> amount <= max
    end

    above_min and below_max
  end

  defp compute_confidence(rule, transaction) do
    signal_count = [
      Map.has_key?(rule, :mcc_codes) and match?(%{mcc_code: _}, transaction),
      Map.has_key?(rule, :merchant_pattern),
      Map.has_key?(rule, :description_keywords)
    ]
    |> Enum.count(& &1)

    cond do
      signal_count >= 2 -> :high
      signal_count == 1 -> :medium
      true -> :low
    end
  end
end
```
