```elixir
defmodule Lending.Loans.AmortisationScheduler do
  @moduledoc """
  Generates full amortisation schedules for fixed-rate instalment loans.
  All monetary values are integer cents; interest is computed using the
  reducing balance method with configurable compounding frequency.
  """

  @type instalment :: %{
          period: pos_integer(),
          opening_balance_cents: non_neg_integer(),
          principal_cents: non_neg_integer(),
          interest_cents: non_neg_integer(),
          closing_balance_cents: non_neg_integer(),
          due_on: Date.t()
        }

  @type schedule :: %{
          instalments: [instalment()],
          total_principal_cents: non_neg_integer(),
          total_interest_cents: non_neg_integer(),
          total_repayable_cents: non_neg_integer()
        }

  @doc """
  Generates an amortisation schedule for a loan.

  ## Parameters
    - `principal_cents` - initial loan principal in cents
    - `annual_rate` - annual interest rate as a decimal (e.g. 0.065 for 6.5%)
    - `periods` - total number of repayment periods
    - `first_due_on` - date of the first instalment

  ## Options
    - `:periods_per_year` - compounding frequency (default: 12 for monthly)
  """
  @spec generate(pos_integer(), float(), pos_integer(), Date.t(), keyword()) ::
          {:ok, schedule()} | {:error, String.t()}
  def generate(principal_cents, annual_rate, periods, %Date{} = first_due_on, opts \\ [])
      when is_integer(principal_cents) and principal_cents > 0 and
             is_float(annual_rate) and annual_rate > 0.0 and
             is_integer(periods) and periods > 0 do
    periods_per_year = Keyword.get(opts, :periods_per_year, 12)
    periodic_rate = annual_rate / periods_per_year
    instalment_cents = compute_instalment(principal_cents, periodic_rate, periods)

    {instalments, _} =
      Enum.map_reduce(1..periods, principal_cents, fn period, balance ->
        due_on = advance_date(first_due_on, period - 1, periods_per_year)
        interest = round(balance * periodic_rate)
        principal = instalment_cents - interest
        adjusted_principal = if period == periods, do: balance, else: min(principal, balance)
        closing = max(balance - adjusted_principal, 0)

        instalment = %{
          period: period,
          opening_balance_cents: balance,
          principal_cents: adjusted_principal,
          interest_cents: interest,
          closing_balance_cents: closing,
          due_on: due_on
        }

        {instalment, closing}
      end)

    total_principal = Enum.reduce(instalments, 0, fn i, acc -> acc + i.principal_cents end)
    total_interest = Enum.reduce(instalments, 0, fn i, acc -> acc + i.interest_cents end)

    {:ok,
     %{
       instalments: instalments,
       total_principal_cents: total_principal,
       total_interest_cents: total_interest,
       total_repayable_cents: total_principal + total_interest
     }}
  end

  def generate(_principal, _rate, _periods, _date, _opts) do
    {:error, "principal_cents and periods must be positive integers; annual_rate a positive float"}
  end

  defp compute_instalment(principal_cents, periodic_rate, periods) do
    factor = :math.pow(1.0 + periodic_rate, periods)
    raw = principal_cents * (periodic_rate * factor) / (factor - 1.0)
    round(raw)
  end

  defp advance_date(base_date, offset_periods, 12) do
    months = offset_periods
    total_months = base_date.month - 1 + months
    year = base_date.year + div(total_months, 12)
    month = rem(total_months, 12) + 1
    day = min(base_date.day, Date.days_in_month(%{base_date | year: year, month: month}))
    %{base_date | year: year, month: month, day: day}
  end

  defp advance_date(base_date, offset_periods, periods_per_year) do
    days_per_period = div(365, periods_per_year)
    Date.add(base_date, offset_periods * days_per_period)
  end
end
```
