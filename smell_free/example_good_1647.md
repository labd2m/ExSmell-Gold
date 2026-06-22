```elixir
defmodule Payroll.Processing.PayslipCalculator do
  @moduledoc """
  Computes employee payslips including gross pay, statutory deductions,
  and net pay for a given pay period.

  Supports hourly and salaried employees using a unified calculation interface
  backed by pay component structs.
  """

  alias Payroll.Processing.{Employee, PayPeriod, PayComponent, TaxTable, Payslip}

  @type calculation_result ::
          {:ok, Payslip.t()} | {:error, :missing_tax_bracket} | {:error, :invalid_pay_period}

  @doc """
  Calculates the payslip for a given employee and pay period.
  """
  @spec calculate(Employee.t(), PayPeriod.t(), TaxTable.t()) :: calculation_result()
  def calculate(%Employee{} = employee, %PayPeriod{} = period, %TaxTable{} = tax_table) do
    with :ok <- validate_pay_period(period),
         {:ok, gross} <- compute_gross(employee, period),
         {:ok, deductions} <- compute_deductions(gross, employee, tax_table),
         net <- Decimal.sub(gross, total_deductions(deductions)) do
      payslip = %Payslip{
        employee_id: employee.id,
        pay_period: period,
        gross_pay: gross,
        deductions: deductions,
        net_pay: net,
        generated_at: DateTime.utc_now()
      }

      {:ok, payslip}
    end
  end

  defp validate_pay_period(%PayPeriod{start_date: s, end_date: e}) do
    if Date.compare(s, e) == :lt, do: :ok, else: {:error, :invalid_pay_period}
  end

  defp compute_gross(%Employee{employment_type: :salaried, annual_salary: salary}, period) do
    period_fraction = period_days(period) / 365.0
    gross = Decimal.mult(salary, Decimal.from_float(period_fraction))
    {:ok, Decimal.round(gross, 2)}
  end

  defp compute_gross(%Employee{employment_type: :hourly, hourly_rate: rate}, period) do
    regular_hours = Decimal.new(period.regular_hours)
    overtime_hours = Decimal.new(period.overtime_hours)
    overtime_rate = Decimal.mult(rate, Decimal.new("1.5"))

    gross =
      Decimal.add(
        Decimal.mult(rate, regular_hours),
        Decimal.mult(overtime_rate, overtime_hours)
      )

    {:ok, Decimal.round(gross, 2)}
  end

  defp compute_deductions(gross, employee, tax_table) do
    with {:ok, income_tax} <- apply_income_tax(gross, tax_table),
         social_contribution <- compute_social_contribution(gross, employee),
         pension <- compute_pension(gross, employee) do
      deductions = [
        %PayComponent{label: "Income Tax", amount: income_tax},
        %PayComponent{label: "Social Contribution", amount: social_contribution},
        %PayComponent{label: "Pension", amount: pension}
      ]

      {:ok, deductions}
    end
  end

  defp apply_income_tax(gross, %TaxTable{brackets: brackets}) do
    matching =
      brackets
      |> Enum.sort_by(& &1.lower_bound, :desc)
      |> Enum.find(fn b -> Decimal.compare(gross, b.lower_bound) in [:gt, :eq] end)

    case matching do
      nil -> {:error, :missing_tax_bracket}
      bracket -> {:ok, Decimal.round(Decimal.mult(gross, bracket.rate), 2)}
    end
  end

  defp compute_social_contribution(gross, %Employee{social_contribution_rate: rate}) do
    Decimal.round(Decimal.mult(gross, rate), 2)
  end

  defp compute_pension(gross, %Employee{pension_rate: rate}) do
    Decimal.round(Decimal.mult(gross, rate), 2)
  end

  defp total_deductions(deductions) do
    Enum.reduce(deductions, Decimal.new("0"), fn %PayComponent{amount: amt}, acc ->
      Decimal.add(acc, amt)
    end)
  end

  defp period_days(%PayPeriod{start_date: s, end_date: e}) do
    Date.diff(e, s)
  end
end
```
