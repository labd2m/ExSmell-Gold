```elixir
defmodule LoanService do
  @moduledoc """
  Provides loan payment calculations, amortisation schedules, and early-payoff summaries.
  """

  alias Finance.{Loan, AmortizationEntry, Customer, DocumentStore}

  @months_per_year 12
  @rounding_scale 2

  def calculate_monthly_payment(%Loan{} = loan) do
    monthly_rate = Decimal.div(loan.annual_interest_rate, Decimal.new(@months_per_year))

    payment =
      if Decimal.eq?(monthly_rate, Decimal.new("0")) do
        Decimal.div(loan.principal, Decimal.new(loan.term_months))
      else
        r = monthly_rate
        n = Decimal.new(loan.term_months)
        one_plus_r_n = pow_decimal(Decimal.add(Decimal.new("1"), r), loan.term_months)

        numerator = Decimal.mult(loan.principal, Decimal.mult(r, one_plus_r_n))
        denominator = Decimal.sub(one_plus_r_n, Decimal.new("1"))
        Decimal.div(numerator, denominator)
      end

    {:ok, Decimal.round(payment, @rounding_scale)}
  end

  def generate_amortization_schedule(%Loan{} = loan) do
    monthly_rate = Decimal.div(loan.annual_interest_rate, Decimal.new(@months_per_year))

    payment =
      if Decimal.eq?(monthly_rate, Decimal.new("0")) do
        Decimal.div(loan.principal, Decimal.new(loan.term_months))
      else
        r = monthly_rate
        n = Decimal.new(loan.term_months)
        one_plus_r_n = pow_decimal(Decimal.add(Decimal.new("1"), r), loan.term_months)

        numerator = Decimal.mult(loan.principal, Decimal.mult(r, one_plus_r_n))
        denominator = Decimal.sub(one_plus_r_n, Decimal.new("1"))
        Decimal.div(numerator, denominator)
      end

    payment = Decimal.round(payment, @rounding_scale)

    {entries, _} =
      Enum.reduce(1..loan.term_months, {[], loan.principal}, fn month, {acc, balance} ->
        interest = Decimal.mult(balance, monthly_rate) |> Decimal.round(@rounding_scale)
        principal_paid = Decimal.sub(payment, interest) |> Decimal.round(@rounding_scale)
        new_balance = Decimal.sub(balance, principal_paid) |> Decimal.round(@rounding_scale)

        entry = %AmortizationEntry{
          month: month,
          payment: payment,
          principal: principal_paid,
          interest: interest,
          balance: Decimal.max(new_balance, Decimal.new("0"))
        }

        {[entry | acc], new_balance}
      end)

    {:ok, Enum.reverse(entries)}
  end

  def early_payoff_summary(%Loan{} = loan, extra_monthly_payment) do
    {:ok, schedule} = generate_amortization_schedule(loan)
    total_interest = Enum.sum(Enum.map(schedule, & &1.interest))

    remaining_months =
      Enum.find_index(schedule, fn e ->
        Decimal.lt?(e.balance, extra_monthly_payment)
      end) || loan.term_months

    %{
      original_term_months: loan.term_months,
      payoff_month: remaining_months,
      interest_saved: Decimal.round(total_interest, @rounding_scale)
    }
  end

  defp pow_decimal(base, exp) do
    Enum.reduce(1..exp, Decimal.new("1"), fn _, acc -> Decimal.mult(acc, base) end)
  end
end
```
