# File: `example_good_234.md`

```elixir
defmodule Payments.FraudDetector do
  @moduledoc """
  Rule-based fraud scoring engine that evaluates payment transactions
  against a configurable set of weighted signal rules.

  Each rule contributes a score delta. The final aggregate score is
  compared against configurable thresholds to produce an :allow,
  :review, or :block decision. All evaluation is pure and side-effect
  free; I/O for velocity lookups is delegated to injected adapters.
  """

  @type transaction :: %{
          required(:id) => String.t(),
          required(:amount_cents) => pos_integer(),
          required(:currency) => String.t(),
          required(:customer_id) => String.t(),
          required(:ip_address) => String.t(),
          required(:card_country) => String.t(),
          required(:billing_country) => String.t()
        }

  @type signal :: %{name: atom(), score: integer(), matched: boolean()}

  @type evaluation :: %{
          transaction_id: String.t(),
          total_score: integer(),
          decision: :allow | :review | :block,
          signals: [signal()]
        }

  @type thresholds :: %{review: integer(), block: integer()}
  @type velocity :: %{transactions_last_hour: non_neg_integer(), distinct_ips_last_day: non_neg_integer()}

  @default_thresholds %{review: 40, block: 75}

  @doc """
  Evaluates a transaction and returns a structured fraud evaluation.

  `velocity` contains pre-fetched velocity statistics for the customer.
  `thresholds` controls the score cutoffs for each decision tier.
  """
  @spec evaluate(transaction(), velocity(), thresholds()) :: evaluation()
  def evaluate(%{} = txn, velocity, thresholds \\ @default_thresholds) do
    signals = run_all_rules(txn, velocity)
    total_score = Enum.sum(Enum.map(signals, & &1.score))
    decision = classify(total_score, thresholds)

    %{
      transaction_id: txn.id,
      total_score: total_score,
      decision: decision,
      signals: signals
    }
  end

  @doc """
  Returns only the signals that matched (contributed a non-zero score)
  from a completed evaluation.
  """
  @spec matched_signals(evaluation()) :: [signal()]
  def matched_signals(%{signals: signals}) do
    Enum.filter(signals, & &1.matched)
  end

  defp run_all_rules(txn, velocity) do
    [
      rule(:high_amount, score_high_amount(txn.amount_cents)),
      rule(:country_mismatch, score_country_mismatch(txn.card_country, txn.billing_country)),
      rule(:high_velocity, score_velocity(velocity.transactions_last_hour)),
      rule(:ip_hopping, score_ip_hopping(velocity.distinct_ips_last_day)),
      rule(:unusual_currency, score_unusual_currency(txn.currency, txn.billing_country))
    ]
  end

  defp rule(name, score) do
    %{name: name, score: score, matched: score > 0}
  end

  defp score_high_amount(amount_cents) do
    cond do
      amount_cents > 100_000_00 -> 40
      amount_cents > 50_000_00 -> 20
      amount_cents > 10_000_00 -> 10
      true -> 0
    end
  end

  defp score_country_mismatch(card_country, billing_country) do
    if card_country != billing_country, do: 25, else: 0
  end

  defp score_velocity(transactions_last_hour) do
    cond do
      transactions_last_hour > 20 -> 35
      transactions_last_hour > 10 -> 20
      transactions_last_hour > 5 -> 10
      true -> 0
    end
  end

  defp score_ip_hopping(distinct_ips) do
    cond do
      distinct_ips > 5 -> 30
      distinct_ips > 3 -> 15
      true -> 0
    end
  end

  defp score_unusual_currency(currency, billing_country) do
    expected = expected_currency(billing_country)
    if expected != nil and currency != expected, do: 15, else: 0
  end

  defp expected_currency("US"), do: "USD"
  defp expected_currency("GB"), do: "GBP"
  defp expected_currency("DE"), do: "EUR"
  defp expected_currency("FR"), do: "EUR"
  defp expected_currency("JP"), do: "JPY"
  defp expected_currency("CA"), do: "CAD"
  defp expected_currency(_), do: nil

  defp classify(score, %{block: block}) when score >= block, do: :block
  defp classify(score, %{review: review}) when score >= review, do: :review
  defp classify(_score, _thresholds), do: :allow
end
```
