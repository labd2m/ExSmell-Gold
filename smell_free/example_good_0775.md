```elixir
defmodule Analytics.KPICalculator do
  @moduledoc """
  Calculates key performance indicators from structured metric inputs.
  All computations are pure functions operating on plain maps; no database
  or process dependency is required. KPIs include conversion rate, average
  revenue per user, churn rate, and customer lifetime value.
  """

  @type period_metrics :: %{
          total_visitors: non_neg_integer(),
          converted_visitors: non_neg_integer(),
          total_revenue_cents: non_neg_integer(),
          paying_users: non_neg_integer(),
          churned_users: non_neg_integer(),
          active_users_start: non_neg_integer(),
          avg_customer_lifespan_months: float()
        }

  @type kpi_snapshot :: %{
          conversion_rate: float(),
          arpu_cents: float(),
          churn_rate: float(),
          ltv_cents: float(),
          revenue_per_visitor_cents: float()
        }

  @doc "Computes all KPIs from `metrics`. Returns a snapshot map."
  @spec compute(period_metrics()) :: kpi_snapshot()
  def compute(%{} = metrics) do
    cr = conversion_rate(metrics)
    arpu = arpu_cents(metrics)
    churn = churn_rate(metrics)
    ltv = ltv_cents(arpu, churn)
    rpv = revenue_per_visitor_cents(metrics)

    %{
      conversion_rate: cr,
      arpu_cents: arpu,
      churn_rate: churn,
      ltv_cents: ltv,
      revenue_per_visitor_cents: rpv
    }
  end

  @doc "Returns the visitor-to-paying-customer conversion rate as a percentage."
  @spec conversion_rate(period_metrics()) :: float()
  def conversion_rate(%{total_visitors: 0}), do: 0.0

  def conversion_rate(%{total_visitors: total, converted_visitors: converted}) do
    Float.round(converted / total * 100, 2)
  end

  @doc "Returns the average revenue per paying user in cents."
  @spec arpu_cents(period_metrics()) :: float()
  def arpu_cents(%{paying_users: 0}), do: 0.0

  def arpu_cents(%{total_revenue_cents: revenue, paying_users: users}) do
    Float.round(revenue / users, 2)
  end

  @doc "Returns the monthly churn rate as a percentage."
  @spec churn_rate(period_metrics()) :: float()
  def churn_rate(%{active_users_start: 0}), do: 0.0

  def churn_rate(%{churned_users: churned, active_users_start: start_count}) do
    Float.round(churned / start_count * 100, 2)
  end

  @doc """
  Returns the estimated customer lifetime value in cents given ARPU and
  a churn rate percentage. Returns 0.0 when churn rate is 100%.
  """
  @spec ltv_cents(float(), float()) :: float()
  def ltv_cents(_arpu, 100.0), do: 0.0
  def ltv_cents(arpu, churn_rate) when is_float(arpu) and is_float(churn_rate) do
    if churn_rate <= 0.0 do
      0.0
    else
      Float.round(arpu / (churn_rate / 100), 2)
    end
  end

  @doc "Returns revenue divided by total visitors in cents."
  @spec revenue_per_visitor_cents(period_metrics()) :: float()
  def revenue_per_visitor_cents(%{total_visitors: 0}), do: 0.0

  def revenue_per_visitor_cents(%{total_revenue_cents: rev, total_visitors: visitors}) do
    Float.round(rev / visitors, 2)
  end

  @doc "Formats a KPI snapshot as a human-readable string for reporting."
  @spec format(kpi_snapshot()) :: String.t()
  def format(%{} = kpi) do
    """
    Conversion Rate       : #{kpi.conversion_rate}%
    ARPU                  : #{format_dollars(kpi.arpu_cents)}
    Churn Rate            : #{kpi.churn_rate}%
    LTV                   : #{format_dollars(kpi.ltv_cents)}
    Revenue per Visitor   : #{format_dollars(kpi.revenue_per_visitor_cents)}
    """
    |> String.trim()
  end

  defp format_dollars(cents) do
    "$#{Float.round(cents / 100, 2)}"
  end
end
```
