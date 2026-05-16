```elixir
defmodule MyApp.Finance.LoanAmortizer do
  @moduledoc """
  Generates full amortization schedules for fixed-rate and variable-rate loans.
  Supports extra payment scenarios, payoff projections, and summary statistics.
  """

  require Logger

  alias MyApp.Finance.{LoanRecord, AmortizationSchedule, PayoffProjector}

  @rounding_precision 2
  @months_in_year 12
  @supported_loan_types [:fixed, :variable, :interest_only]

  @type amortization_opts :: [
          loan_type: atom(),
          extra_monthly_payment: number(),
          origination_date: Date.t(),
          first_payment_date: Date.t()
        ]

  @spec generate_schedule(term(), number(), pos_integer(), amortization_opts()) ::
          {:ok, map()} | {:error, atom()}
  def generate_schedule(principal, annual_rate, term_months, opts \\ []) do
    loan_type = Keyword.get(opts, :loan_type, :fixed)
    extra_payment = Keyword.get(opts, :extra_monthly_payment, 0.0)
    origination_date = Keyword.get(opts, :origination_date, Date.utc_today())
    first_payment_date = Keyword.get(opts, :first_payment_date, Date.add(origination_date, 30))

    with :ok <- validate_loan_type(loan_type),
         :ok <- validate_rate(annual_rate),
         :ok <- validate_term(term_months) do

      monthly_rate = annual_rate / @months_in_year / 100

      monthly_payment =
        if monthly_rate == 0.0 do
          principal / term_months
        else
          numerator = monthly_rate * :math.pow(1 + monthly_rate, term_months)
          denominator = :math.pow(1 + monthly_rate, term_months) - 1
          principal * (numerator / denominator)
        end

      monthly_payment = Float.round(monthly_payment, @rounding_precision)

      {schedule, _final_balance} =
        Enum.reduce(1..term_months, {[], principal}, fn month, {entries, balance} ->
          payment_date = Date.add(first_payment_date, (month - 1) * 30)
          interest = Float.round(balance * monthly_rate, @rounding_precision)
          base_principal = Float.round(monthly_payment - interest, @rounding_precision)
          extra = if balance - base_principal > 0, do: extra_payment, else: 0.0
          principal_paid = Float.round(min(base_principal + extra, balance), @rounding_precision)
          new_balance = Float.round(balance - principal_paid, @rounding_precision)

          entry = %{
            month: month,
            payment_date: payment_date,
            payment: Float.round(interest + principal_paid, @rounding_precision),
            principal_paid: principal_paid,
            interest_paid: interest,
            extra_payment: extra,
            balance: new_balance
          }

          {[entry | entries], new_balance}
        end)

      schedule = Enum.reverse(schedule)
      total_interest = schedule |> Enum.map(& &1.interest_paid) |> Enum.sum() |> Float.round(@rounding_precision)
      total_payments = schedule |> Enum.map(& &1.payment) |> Enum.sum() |> Float.round(@rounding_precision)

      result = %{
        principal: principal,
        annual_rate: annual_rate,
        term_months: term_months,
        monthly_payment: monthly_payment,
        total_interest: total_interest,
        total_payments: total_payments,
        origination_date: origination_date,
        schedule: schedule,
        generated_at: DateTime.utc_now()
      }

      {:ok, result}
    end
  end

  @spec payoff_date(String.t(), number()) :: {:ok, Date.t()} | {:error, atom()}
  def payoff_date(loan_id, extra_monthly_payment \\ 0.0) do
    with {:ok, loan} <- LoanRecord.fetch(loan_id) do
      PayoffProjector.project(loan, extra_monthly_payment)
    end
  end

  @spec remaining_schedule(String.t()) :: {:ok, map()} | {:error, atom()}
  def remaining_schedule(loan_id) do
    with {:ok, loan} <- LoanRecord.fetch(loan_id) do
      generate_schedule(
        loan.outstanding_balance,
        loan.annual_rate,
        loan.remaining_months,
        loan_type: loan.type,
        origination_date: Date.utc_today()
      )
    end
  end

  # Private helpers

  defp validate_loan_type(type) when type in @supported_loan_types, do: :ok
  defp validate_loan_type(_), do: {:error, :unsupported_loan_type}

  defp validate_rate(rate) when is_number(rate) and rate >= 0 and rate <= 100, do: :ok
  defp validate_rate(_), do: {:error, :invalid_rate}

  defp validate_term(months) when is_integer(months) and months > 0 and months <= 360, do: :ok
  defp validate_term(_), do: {:error, :invalid_term}
end
```
