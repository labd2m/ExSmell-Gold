```elixir
defmodule HR.TaxUtils do
  @moduledoc """
  Federal and state income-tax withholding utilities for payroll processing.
  """

  @federal_brackets [
    {0,      11_000,  0.10},
    {11_000, 44_725,  0.12},
    {44_725, 95_375,  0.22},
    {95_375, 201_050, 0.24}
  ]

  def federal_withholding(annual_gross_cents) do
    annual = annual_gross_cents / 100

    tax =
      Enum.reduce(@federal_brackets, 0.0, fn {low, high, rate}, acc ->
        if annual > low do
          taxable = min(annual, high) - low
          acc + taxable * rate
        else
          acc
        end
      end)

    round(tax * 100)
  end

  def fica_employee(gross_cents) do
    ss    = min(gross_cents, 16_080_000) |> then(&round(&1 * 0.062))
    med   = round(gross_cents * 0.0145)
    ss + med
  end

  def state_withholding(gross_cents, state_rate) do
    round(gross_cents * state_rate)
  end
end

defmodule HR.ComplianceHelpers do
  @moduledoc """
  Labor-law compliance validation helpers shared across HR modules via `use`.
  """

  @min_wage_cents 725  # $7.25/hr federal minimum
  @max_weekly_hours 40
  @overtime_multiplier 1.5

  defmacro __using__(_opts) do
    quote do
      import HR.TaxUtils  # propagates tax dependency into every caller

      def above_minimum_wage?(hourly_rate_cents) do
        hourly_rate_cents >= unquote(@min_wage_cents)
      end

      def overtime_hours(total_hours) do
        max(0.0, total_hours - unquote(@max_weekly_hours))
      end

      def regular_hours(total_hours) do
        min(total_hours, unquote(@max_weekly_hours))
      end

      def overtime_multiplier, do: unquote(@overtime_multiplier)

      def validate_pay_period(start_date, end_date) do
        days = Date.diff(end_date, start_date)

        cond do
          days <= 0   -> {:error, :end_before_start}
          days > 31   -> {:error, :period_too_long}
          true        -> :ok
        end
      end

      def eligible_for_overtime?(employment_type) do
        employment_type in [:hourly, :part_time]
      end
    end
  end
end

defmodule HR.PayrollCalculator do
  @moduledoc """
  Calculates gross pay, deductions, tax withholdings, and net pay for
  hourly and salaried employees across a pay period.
  """

  use HR.ComplianceHelpers

  @state_tax_rate 0.05

  def compute(employee, hours_worked, pay_period) do
    with :ok <- validate_pay_period(pay_period.start_date, pay_period.end_date),
         :ok <- check_minimum_wage(employee) do
      gross     = gross_pay(employee, hours_worked)
      fed_tax   = federal_withholding(annualize(gross, pay_period))
      state_tax = state_withholding(gross, @state_tax_rate)
      fica      = fica_employee(gross)
      net       = gross - fed_tax - state_tax - fica

      {:ok, %{
        employee_id:   employee.id,
        period_start:  pay_period.start_date,
        period_end:    pay_period.end_date,
        hours_worked:  hours_worked,
        gross_cents:   gross,
        federal_tax:   fed_tax,
        state_tax:     state_tax,
        fica:          fica,
        net_cents:     net,
        computed_at:   DateTime.utc_now()
      }}
    end
  end

  def gross_pay(%{employment_type: :hourly, hourly_rate_cents: rate} = _employee, hours) do
    reg    = regular_hours(hours)
    ot     = overtime_hours(hours)
    reg_pay = round(reg * rate)
    ot_pay  = round(ot * rate * overtime_multiplier())
    reg_pay + ot_pay
  end

  def gross_pay(%{employment_type: :salaried, annual_salary_cents: salary}, _hours) do
    round(salary / 26)  # bi-weekly
  end

  def year_to_date_summary(payslips) do
    %{
      gross_ytd:   Enum.sum(Enum.map(payslips, & &1.gross_cents)),
      tax_ytd:     Enum.sum(Enum.map(payslips, &(&1.federal_tax + &1.state_tax))),
      fica_ytd:    Enum.sum(Enum.map(payslips, & &1.fica)),
      net_ytd:     Enum.sum(Enum.map(payslips, & &1.net_cents)),
      periods:     length(payslips)
    }
  end

  defp check_minimum_wage(%{hourly_rate_cents: rate}) do
    if above_minimum_wage?(rate), do: :ok, else: {:error, :below_minimum_wage}
  end

  defp check_minimum_wage(%{employment_type: :salaried}), do: :ok

  defp annualize(gross_cents, pay_period) do
    period_days = Date.diff(pay_period.end_date, pay_period.start_date)
    round(gross_cents * 365 / max(period_days, 1))
  end
end
```
