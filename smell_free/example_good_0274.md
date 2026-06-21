```elixir
defmodule MyApp.Billing.ProrationCalculator do
  @moduledoc """
  Calculates prorated charges and credits when a customer changes their
  subscription plan mid-billing-cycle. All arithmetic is performed in
  integer cents to avoid floating-point rounding errors. The module is
  purely functional with no side effects or process dependencies.
  """

  @type plan :: %{
          required(:slug) => String.t(),
          required(:price_cents) => non_neg_integer(),
          required(:interval) => :monthly | :annual
        }

  @type proration :: %{
          days_remaining: non_neg_integer(),
          days_in_cycle: pos_integer(),
          credit_cents: non_neg_integer(),
          charge_cents: non_neg_integer(),
          net_cents: integer()
        }

  @doc """
  Computes the proration between `old_plan` and `new_plan` for a change
  occurring on `change_date` within a billing cycle that started on
  `cycle_start`. Returns a `proration` map with credit, charge, and net
  amounts in cents.
  """
  @spec calculate(plan(), plan(), Date.t(), Date.t()) :: proration()
  def calculate(old_plan, new_plan, cycle_start, change_date) do
    cycle_days = days_in_cycle(old_plan.interval, cycle_start)
    days_remaining = days_remaining(cycle_start, change_date, cycle_days)

    credit_cents = prorate(old_plan.price_cents, days_remaining, cycle_days)
    charge_cents = prorate(new_plan.price_cents, days_remaining, cycle_days)

    %{
      days_remaining: days_remaining,
      days_in_cycle: cycle_days,
      credit_cents: credit_cents,
      charge_cents: charge_cents,
      net_cents: charge_cents - credit_cents
    }
  end

  @doc """
  Returns `true` when the net proration results in an additional charge
  (i.e. the customer is upgrading to a more expensive plan).
  """
  @spec upgrade?(proration()) :: boolean()
  def upgrade?(%{net_cents: net}), do: net > 0

  @doc """
  Returns `true` when the net proration results in a credit
  (i.e. the customer is downgrading to a cheaper plan).
  """
  @spec downgrade?(proration()) :: boolean()
  def downgrade?(%{net_cents: net}), do: net < 0

  @spec prorate(non_neg_integer(), non_neg_integer(), pos_integer()) :: non_neg_integer()
  defp prorate(price_cents, days_remaining, cycle_days) do
    round(price_cents * days_remaining / cycle_days)
  end

  @spec days_in_cycle(:monthly | :annual, Date.t()) :: pos_integer()
  defp days_in_cycle(:monthly, cycle_start) do
    cycle_end = cycle_start |> Date.end_of_month()
    Date.diff(cycle_end, cycle_start) + 1
  end

  defp days_in_cycle(:annual, cycle_start) do
    cycle_end = %{cycle_start | year: cycle_start.year + 1} |> Date.add(-1)
    Date.diff(cycle_end, cycle_start) + 1
  end

  @spec days_remaining(Date.t(), Date.t(), pos_integer()) :: non_neg_integer()
  defp days_remaining(cycle_start, change_date, cycle_days) do
    elapsed = Date.diff(change_date, cycle_start)
    max(cycle_days - elapsed, 0)
  end
end
```
