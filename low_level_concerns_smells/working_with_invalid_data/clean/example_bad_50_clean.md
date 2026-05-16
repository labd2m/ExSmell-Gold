# Example 50: Payroll Tax Withholding Calculator

```elixir
defmodule Payroll.TaxWithholding do
  @moduledoc """
  Calculates federal, state, and local tax withholding for employee
  paychecks, applying current bracket schedules and filing-status adjustments.
  """

  alias Payroll.{Employee, TaxBracket, WithholdingRecord, PayPeriod, AuditLog}

  @federal_brackets_single [
    {0,       11_600,  0.10},
    {11_600,  47_150,  0.12},
    {47_150,  100_525, 0.22},
    {100_525, 191_950, 0.24},
    {191_950, 243_725, 0.32},
    {243_725, 609_350, 0.35},
    {609_350, :inf,    0.37}
  ]

  @federal_brackets_married [
    {0,       23_200,  0.10},
    {23_200,  94_300,  0.12},
    {94_300,  201_050, 0.22},
    {201_050, 383_900, 0.24},
    {383_900, 487_450, 0.32},
    {487_450, 731_200, 0.35},
    {731_200, :inf,    0.37}
  ]

  @fica_social_security_rate 0.062
  @fica_medicare_rate 0.0145
  @social_security_wage_base 168_600

  def fetch_withholding_summary(employee_id, tax_year) do
    with {:ok, employee} <- Employee.get(employee_id),
         {:ok, records} <- WithholdingRecord.list_for_employee_year(employee_id, tax_year) do

      total_federal = Enum.sum(Enum.map(records, & &1.federal_income_tax))
      total_state = Enum.sum(Enum.map(records, & &1.state_income_tax))
      total_fica = Enum.sum(Enum.map(records, & &1.fica_total))
      total_gross = Enum.sum(Enum.map(records, & &1.gross_wages))

      {:ok, %{
        employee_id: employee_id,
        tax_year: tax_year,
        pay_periods: length(records),
        ytd_gross: Float.round(total_gross, 2),
        ytd_federal_withheld: Float.round(total_federal, 2),
        ytd_state_withheld: Float.round(total_state, 2),
        ytd_fica: Float.round(total_fica, 2),
        ytd_total_withheld: Float.round(total_federal + total_state + total_fica, 2)
      }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def compute_withholding(employee_id, pay_period_id, gross_wages) do
    with {:ok, employee} <- Employee.get(employee_id),
         {:ok, pay_period} <- PayPeriod.get(pay_period_id),
         {:ok, ytd_wages} <- get_ytd_wages(employee_id, pay_period.tax_year) do

      annualized_wages = gross_wages * pay_period.periods_per_year
      brackets = select_brackets(employee.filing_status)

      annualized_federal = apply_tax_brackets(annualized_wages, brackets)
      federal_withheld = annualized_federal / pay_period.periods_per_year

      state_withheld = compute_state_withholding(gross_wages, employee.state, employee.filing_status)

      ss_wages = min(gross_wages, max(0, @social_security_wage_base - ytd_wages))
      social_security = ss_wages * @fica_social_security_rate
      medicare = gross_wages * @fica_medicare_rate
      fica_total = social_security + medicare

      record = %WithholdingRecord{
        id: generate_record_id(),
        employee_id: employee_id,
        pay_period_id: pay_period_id,
        gross_wages: gross_wages,
        federal_income_tax: Float.round(federal_withheld, 2),
        state_income_tax: Float.round(state_withheld, 2),
        social_security_tax: Float.round(social_security, 2),
        medicare_tax: Float.round(medicare, 2),
        fica_total: Float.round(fica_total, 2),
        total_withheld: Float.round(federal_withheld + state_withheld + fica_total, 2),
        net_pay: Float.round(gross_wages - federal_withheld - state_withheld - fica_total, 2),
        computed_at: DateTime.utc_now()
      }

      {:ok, _} = WithholdingRecord.insert(record)
      {:ok, _} = AuditLog.record(:withholding_computed, employee_id, %{record_id: record.id, period: pay_period_id})

      {:ok, record}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def adjust_withholding(record_id, adjustment_amount, reason) do
    with {:ok, record} <- WithholdingRecord.get(record_id),
         :ok <- validate_adjustable(record) do

      new_federal = max(0, record.federal_income_tax + adjustment_amount)
      new_total = record.state_income_tax + new_federal + record.fica_total
      new_net = record.gross_wages - new_total

      {:ok, _} = WithholdingRecord.update(record_id, %{
        federal_income_tax: Float.round(new_federal, 2),
        total_withheld: Float.round(new_total, 2),
        net_pay: Float.round(new_net, 2),
        adjustment_reason: reason,
        adjusted_at: DateTime.utc_now()
      })

      {:ok, :adjusted}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def generate_w2_preview(employee_id, tax_year) do
    with {:ok, employee} <- Employee.get(employee_id),
         {:ok, summary} <- fetch_withholding_summary(employee_id, tax_year) do

      {:ok, %{
        employee_id: employee_id,
        employee_name: employee.full_name,
        employer_ein: employee.employer_ein,
        tax_year: tax_year,
        box_1_wages: summary.ytd_gross,
        box_2_federal_withheld: summary.ytd_federal_withheld,
        box_4_social_security_withheld: Float.round(summary.ytd_fica * 0.062 / 0.0765, 2),
        box_6_medicare_withheld: Float.round(summary.ytd_fica * 0.0145 / 0.0765, 2),
        box_16_state_wages: summary.ytd_gross,
        box_17_state_withheld: summary.ytd_state_withheld,
        generated_at: DateTime.utc_now()
      }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_tax_brackets(income, brackets) do
    Enum.reduce(brackets, {income, 0.0}, fn {lower, upper, rate}, {remaining, tax} ->
      bracket_max = if upper == :inf, do: remaining, else: min(remaining, upper - lower)
      taxable_in_bracket = min(remaining, bracket_max)
      new_remaining = max(0, remaining - taxable_in_bracket)
      {new_remaining, tax + taxable_in_bracket * rate}
    end)
    |> elem(1)
  end

  defp select_brackets(:single), do: @federal_brackets_single
  defp select_brackets(:married_filing_jointly), do: @federal_brackets_married
  defp select_brackets(:married_filing_separately), do: @federal_brackets_single
  defp select_brackets(:head_of_household), do: @federal_brackets_single

  defp compute_state_withholding(gross_wages, "CA", _filing_status), do: gross_wages * 0.093
  defp compute_state_withholding(_gross_wages, "TX", _filing_status), do: 0.0
  defp compute_state_withholding(gross_wages, "NY", _filing_status), do: gross_wages * 0.0685
  defp compute_state_withholding(gross_wages, _state, _filing_status), do: gross_wages * 0.05

  defp get_ytd_wages(employee_id, tax_year) do
    case WithholdingRecord.sum_gross_wages_for_year(employee_id, tax_year) do
      {:ok, total} -> {:ok, total}
      {:error, _} -> {:ok, 0.0}
    end
  end

  defp validate_adjustable(%{adjusted_at: nil}), do: :ok
  defp validate_adjustable(_), do: {:error, :already_adjusted}

  defp generate_record_id do
    "wh_#{:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)}"
  end
end
```
