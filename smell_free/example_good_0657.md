```elixir
defmodule MyApp.Payments.FraudScorer do
  @moduledoc """
  Computes a real-time fraud risk score for a payment attempt by
  evaluating a set of independent signal functions and combining their
  outputs into a weighted risk score. Scores above configured thresholds
  trigger review or automatic block actions in the caller.

  All signal functions are pure; network or database calls are performed
  in the caller before invoking this module, keeping fraud scoring
  fast and deterministic in tests.
  """

  @type payment_attempt :: %{
          required(:amount_cents) => pos_integer(),
          required(:card_country) => String.t(),
          required(:billing_country) => String.t(),
          required(:ip_country) => String.t() | nil,
          required(:customer_id) => String.t(),
          required(:velocity_1h) => non_neg_integer(),
          required(:velocity_24h) => non_neg_integer(),
          required(:new_card) => boolean(),
          required(:new_device) => boolean()
        }

  @type signal_result :: %{name: String.t(), score: float(), weight: float()}
  @type fraud_assessment :: %{
          risk_score: float(),
          signals: [signal_result()],
          recommendation: :allow | :review | :block
        }

  @review_threshold 40.0
  @block_threshold 70.0

  @signals [
    {"country_mismatch", &__MODULE__.sig_country_mismatch/1, 25.0},
    {"high_velocity_1h", &__MODULE__.sig_high_velocity_1h/1, 20.0},
    {"high_velocity_24h", &__MODULE__.sig_high_velocity_24h/1, 15.0},
    {"large_amount", &__MODULE__.sig_large_amount/1, 20.0},
    {"new_card_new_device", &__MODULE__.sig_new_card_new_device/1, 20.0}
  ]

  @doc """
  Assesses `attempt` and returns a fraud assessment with a risk score,
  per-signal breakdown, and a recommendation.
  """
  @spec assess(payment_attempt()) :: fraud_assessment()
  def assess(attempt) when is_map(attempt) do
    signals =
      Enum.map(@signals, fn {name, fun, weight} ->
        %{name: name, score: fun.(attempt), weight: weight}
      end)

    risk_score =
      Enum.sum_by(signals, fn s -> s.score * s.weight end)
      |> Float.round(2)

    %{
      risk_score: risk_score,
      signals: signals,
      recommendation: recommendation(risk_score)
    }
  end

  @doc false
  @spec sig_country_mismatch(payment_attempt()) :: float()
  def sig_country_mismatch(%{card_country: card, billing_country: billing, ip_country: ip}) do
    mismatches =
      [
        card != billing,
        ip != nil and ip != card,
        ip != nil and ip != billing
      ]
      |> Enum.count(& &1)

    min(mismatches / 3.0, 1.0)
  end

  @doc false
  @spec sig_high_velocity_1h(payment_attempt()) :: float()
  def sig_high_velocity_1h(%{velocity_1h: v}), do: min(v / 5.0, 1.0)

  @doc false
  @spec sig_high_velocity_24h(payment_attempt()) :: float()
  def sig_high_velocity_24h(%{velocity_24h: v}), do: min(v / 20.0, 1.0)

  @doc false
  @spec sig_large_amount(payment_attempt()) :: float()
  def sig_large_amount(%{amount_cents: cents}) do
    cond do
      cents > 50_000_00 -> 1.0
      cents > 10_000_00 -> 0.7
      cents > 5_000_00 -> 0.4
      true -> 0.0
    end
  end

  @doc false
  @spec sig_new_card_new_device(payment_attempt()) :: float()
  def sig_new_card_new_device(%{new_card: true, new_device: true}), do: 1.0
  def sig_new_card_new_device(%{new_card: true}), do: 0.5
  def sig_new_card_new_device(%{new_device: true}), do: 0.3
  def sig_new_card_new_device(_), do: 0.0

  @spec recommendation(float()) :: :allow | :review | :block
  defp recommendation(score) when score >= @block_threshold, do: :block
  defp recommendation(score) when score >= @review_threshold, do: :review
  defp recommendation(_), do: :allow
end
```
