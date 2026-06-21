```elixir
defmodule Payments.FraudScorer do
  @moduledoc """
  Assigns a fraud risk score to payment attempts using a weighted signal
  model. Each signal is a named predicate function that returns a
  numeric weight contribution when it fires. The scorer is entirely pure
  and stateless; all context required for evaluation is provided by the
  caller in a structured transaction attempt map.
  """

  @type tx_attempt :: %{
          user_id: String.t(),
          amount_cents: pos_integer(),
          currency: String.t(),
          ip_address: String.t(),
          device_fingerprint: String.t() | nil,
          card_country: String.t(),
          billing_country: String.t(),
          is_new_card: boolean(),
          velocity_last_hour: non_neg_integer(),
          user_account_age_days: non_neg_integer()
        }

  @type scored_result :: %{
          score: float(),
          risk_level: :low | :medium | :high | :critical,
          fired_signals: [String.t()]
        }

  @risk_thresholds %{low: 0.0, medium: 30.0, high: 60.0, critical: 85.0}

  @signals [
    {"high_amount", 20.0, fn tx -> tx.amount_cents > 50_000 end},
    {"very_high_amount", 15.0, fn tx -> tx.amount_cents > 200_000 end},
    {"new_card", 10.0, fn tx -> tx.is_new_card end},
    {"country_mismatch", 25.0, fn tx -> tx.card_country != tx.billing_country end},
    {"high_velocity", 30.0, fn tx -> tx.velocity_last_hour > 5 end},
    {"new_account", 15.0, fn tx -> tx.user_account_age_days < 7 end},
    {"no_device_fingerprint", 10.0, fn tx -> is_nil(tx.device_fingerprint) end},
    {"known_high_risk_country", 20.0, fn tx -> tx.card_country in ["NG", "RO", "UA"] end}
  ]

  @doc """
  Scores a payment transaction attempt. Returns the numeric score,
  risk level, and the list of signal names that contributed to the score.
  """
  @spec score(tx_attempt()) :: scored_result()
  def score(%{} = tx) do
    {total_score, fired} =
      Enum.reduce(@signals, {0.0, []}, fn {name, weight, predicate}, {score, fired_acc} ->
        if predicate.(tx) do
          {score + weight, [name | fired_acc]}
        else
          {score, fired_acc}
        end
      end)

    capped = min(total_score, 100.0)

    %{
      score: Float.round(capped, 1),
      risk_level: classify_risk(capped),
      fired_signals: Enum.reverse(fired)
    }
  end

  @doc "Returns true when the transaction should be blocked based on its score."
  @spec block?(scored_result()) :: boolean()
  def block?(%{risk_level: level}), do: level == :critical

  @doc "Returns true when the transaction should require additional verification."
  @spec review?(scored_result()) :: boolean()
  def review?(%{risk_level: level}), do: level in [:medium, :high]

  defp classify_risk(score) do
    cond do
      score >= @risk_thresholds.critical -> :critical
      score >= @risk_thresholds.high -> :high
      score >= @risk_thresholds.medium -> :medium
      true -> :low
    end
  end
end
```
