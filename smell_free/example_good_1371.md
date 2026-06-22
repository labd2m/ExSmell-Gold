```elixir
defmodule Crm.Accounts.HealthScorer do
  @moduledoc """
  Computes a health score for a CRM account based on engagement,
  product usage, and support activity signals.
  Scores range from 0 (at-risk) to 100 (healthy).
  """

  @type signal :: %{
          last_login_days_ago: non_neg_integer(),
          feature_adoption_pct: float(),
          support_tickets_open: non_neg_integer(),
          nps_score: integer() | nil,
          contract_days_remaining: integer()
        }

  @type score_breakdown :: %{
          engagement_score: float(),
          adoption_score: float(),
          support_score: float(),
          sentiment_score: float(),
          retention_score: float(),
          composite: float()
        }

  @engagement_weight 0.25
  @adoption_weight 0.30
  @support_weight 0.20
  @sentiment_weight 0.15
  @retention_weight 0.10

  @doc """
  Computes a health score breakdown from the given account signals.
  Returns `{:ok, breakdown}` or `{:error, reason}` on invalid input.
  """
  @spec compute(signal()) :: {:ok, score_breakdown()} | {:error, String.t()}
  def compute(signal) when is_map(signal) do
    with :ok <- validate_signal(signal) do
      engagement = engagement_score(signal.last_login_days_ago)
      adoption = adoption_score(signal.feature_adoption_pct)
      support = support_score(signal.support_tickets_open)
      sentiment = sentiment_score(signal.nps_score)
      retention = retention_score(signal.contract_days_remaining)

      composite =
        engagement * @engagement_weight +
          adoption * @adoption_weight +
          support * @support_weight +
          sentiment * @sentiment_weight +
          retention * @retention_weight

      {:ok,
       %{
         engagement_score: Float.round(engagement, 2),
         adoption_score: Float.round(adoption, 2),
         support_score: Float.round(support, 2),
         sentiment_score: Float.round(sentiment, 2),
         retention_score: Float.round(retention, 2),
         composite: Float.round(composite, 2)
       }}
    end
  end

  @doc """
  Returns the health band for a composite score.
  """
  @spec band(float()) :: :healthy | :neutral | :at_risk
  def band(score) when score >= 70.0, do: :healthy
  def band(score) when score >= 40.0, do: :neutral
  def band(_score), do: :at_risk

  defp engagement_score(days_ago) when days_ago <= 7, do: 100.0
  defp engagement_score(days_ago) when days_ago <= 30, do: 75.0
  defp engagement_score(days_ago) when days_ago <= 60, do: 40.0
  defp engagement_score(_days_ago), do: 10.0

  defp adoption_score(pct) when is_float(pct), do: min(pct, 100.0)

  defp support_score(0), do: 100.0
  defp support_score(1), do: 70.0
  defp support_score(2), do: 40.0
  defp support_score(_), do: 10.0

  defp sentiment_score(nil), do: 50.0
  defp sentiment_score(nps) when nps >= 9, do: 100.0
  defp sentiment_score(nps) when nps >= 7, do: 65.0
  defp sentiment_score(nps) when nps >= 5, do: 35.0
  defp sentiment_score(_nps), do: 5.0

  defp retention_score(days) when days > 180, do: 100.0
  defp retention_score(days) when days > 60, do: 65.0
  defp retention_score(days) when days > 0, do: 30.0
  defp retention_score(_days), do: 0.0

  defp validate_signal(%{
         last_login_days_ago: ld,
         feature_adoption_pct: fp,
         support_tickets_open: st,
         contract_days_remaining: cd
       })
       when is_integer(ld) and ld >= 0 and
              is_float(fp) and fp >= 0.0 and fp <= 100.0 and
              is_integer(st) and st >= 0 and
              is_integer(cd),
       do: :ok

  defp validate_signal(_signal) do
    {:error,
     "signal must contain last_login_days_ago, feature_adoption_pct, support_tickets_open, and contract_days_remaining"}
  end
end
```
