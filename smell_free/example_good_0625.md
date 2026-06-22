```elixir
defmodule Billing.ProrationCalculator do
  @moduledoc """
  Calculates prorated billing amounts when a subscription plan changes
  mid-period. The proration model credits unused days on the old plan and
  charges the proportional cost of the new plan for the remaining days.
  All arithmetic uses integer cent values to avoid floating-point errors.
  """

  @type plan :: %{
          id: String.t(),
          price_cents: pos_integer(),
          interval_days: pos_integer()
        }

  @type period :: %{
          starts_on: Date.t(),
          ends_on: Date.t()
        }

  @type proration_result :: %{
          credit_cents: non_neg_integer(),
          charge_cents: non_neg_integer(),
          net_cents: integer(),
          days_remaining: non_neg_integer(),
          days_elapsed: non_neg_integer(),
          period_days: pos_integer()
        }

  @doc """
  Calculates the proration when switching from `old_plan` to `new_plan`
  on `change_date` within `period`. Returns credit for unused time on the
  old plan, the charge for remaining time on the new plan, and the net
  amount due (negative means a refund credit).
  """
  @spec calculate(plan(), plan(), period(), Date.t()) ::
          {:ok, proration_result()} | {:error, :change_outside_period}
  def calculate(%{} = old_plan, %{} = new_plan, %{starts_on: s, ends_on: e} = _period, change_date) do
    period_days = Date.diff(e, s)

    cond do
      Date.compare(change_date, s) == :lt ->
        {:error, :change_outside_period}

      Date.compare(change_date, e) == :gt ->
        {:error, :change_outside_period}

      true ->
        days_elapsed = Date.diff(change_date, s)
        days_remaining = period_days - days_elapsed

        credit = prorate(old_plan.price_cents, days_remaining, period_days)
        charge = prorate(new_plan.price_cents, days_remaining, period_days)
        net = charge - credit

        {:ok,
         %{
           credit_cents: credit,
           charge_cents: charge,
           net_cents: net,
           days_remaining: days_remaining,
           days_elapsed: days_elapsed,
           period_days: period_days
         }}
    end
  end

  @doc "Returns the prorated cost in cents for `days` out of `total_days` at `full_price_cents`."
  @spec prorate(pos_integer(), non_neg_integer(), pos_integer()) :: non_neg_integer()
  def prorate(_full_price_cents, 0, _total_days), do: 0

  def prorate(full_price_cents, days, total_days)
      when is_integer(full_price_cents) and full_price_cents > 0
      and is_integer(days) and days >= 0
      and is_integer(total_days) and total_days > 0 do
    div(full_price_cents * days, total_days)
  end

  @doc "Returns the unused fraction of a period given the change date."
  @spec remaining_fraction(period(), Date.t()) :: float()
  def remaining_fraction(%{starts_on: s, ends_on: e}, change_date) do
    total = Date.diff(e, s)
    remaining = Date.diff(e, change_date)
    if total > 0, do: Float.round(remaining / total, 6), else: 0.0
  end

  @doc """
  Summarises a proration result as a human-readable string for
  invoice line items.
  """
  @spec describe(proration_result(), String.t()) :: String.t()
  def describe(%{net_cents: net, days_remaining: days}, currency) when net >= 0 do
    amount = format_cents(net, currency)
    "Proration charge for #{days} remaining day(s): #{amount}"
  end

  def describe(%{net_cents: net, days_remaining: days}, currency) do
    amount = format_cents(abs(net), currency)
    "Proration credit for #{days} remaining day(s): −#{amount}"
  end

  defp format_cents(cents, currency) do
    major = div(cents, 100)
    minor = rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{major}.#{minor} #{currency}"
  end
end
```
