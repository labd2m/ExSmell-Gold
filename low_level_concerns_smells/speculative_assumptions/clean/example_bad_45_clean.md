```elixir
defmodule Billing.ProrationCalculator do
  @moduledoc """
  Calculates prorated charges and credits when a subscription plan changes
  mid-billing-cycle. Used during plan upgrades, downgrades, and cancellations.

  Proration logic:
    - Remaining credit  = (days remaining / total days) * current plan price
    - New charge        = (days remaining / total days) * new plan price
    - Net adjustment    = new charge - remaining credit
  """

  require Logger

  @plans %{
    "starter"    => 2900,
    "business"   => 9900,
    "enterprise" => 29900
  }

  def calculate(current_plan, new_plan, opts \\ []) do
    current_date    = Keyword.get(opts, :current_date, Date.utc_today())
    cycle_start     = Keyword.get(opts, :cycle_start)
    cycle_end       = Keyword.get(opts, :cycle_end)

    with {:ok, current_price} <- plan_price(current_plan),
         {:ok, new_price}     <- plan_price(new_plan),
         {:ok, total_days}    <- cycle_length(cycle_start, cycle_end) do

      remaining = days_remaining(current_date, cycle_end)
      remaining_ratio = remaining / total_days

      credit     = round(current_price * remaining_ratio)
      new_charge = round(new_price * remaining_ratio)
      net_adjustment = new_charge - credit

      {:ok, %{
        current_plan:    current_plan,
        new_plan:        new_plan,
        days_remaining:  remaining,
        total_days:      total_days,
        credit_cents:    credit,
        new_charge_cents: new_charge,
        net_adjustment_cents: net_adjustment,
        calculated_at:   DateTime.utc_now()
      }}
    end
  end

  defp days_remaining(current_date, cycle_end_date) do
    Date.diff(cycle_end_date, current_date)
  end

  defp cycle_length(nil, _), do: {:error, :missing_cycle_start}
  defp cycle_length(_, nil), do: {:error, :missing_cycle_end}
  defp cycle_length(start, end_date) do
    days = Date.diff(end_date, start)

    if days > 0 do
      {:ok, days}
    else
      {:error, :invalid_cycle_dates}
    end
  end

  defp plan_price(plan_id) do
    case Map.get(@plans, plan_id) do
      nil   -> {:error, {:unknown_plan, plan_id}}
      price -> {:ok, price}
    end
  end

  def format_adjustment(%{net_adjustment_cents: adj, new_plan: plan}) when adj > 0 do
    "Charge #{format_cents(adj)} for upgrading to #{plan}"
  end

  def format_adjustment(%{net_adjustment_cents: adj, current_plan: plan}) when adj < 0 do
    "Credit #{format_cents(abs(adj))} for downgrading from #{plan}"
  end

  def format_adjustment(_), do: "No adjustment required"

  defp format_cents(cents) do
    "R$ #{div(cents, 100)},#{String.pad_leading(to_string(rem(cents, 100)), 2, "0")}"
  end

  def upgrade?(%{net_adjustment_cents: adj}), do: adj > 0
  def downgrade?(%{net_adjustment_cents: adj}), do: adj < 0

  def apply_adjustment(%{net_adjustment_cents: adj, calculated_at: ts}) do
    Logger.info("Applying billing adjustment: #{adj} cents at #{ts}")
    {:ok, :adjustment_applied}
  end
end
```
