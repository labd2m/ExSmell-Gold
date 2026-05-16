```elixir
defmodule HR.PayrollCalculator do
  @moduledoc """
  Computes gross and net pay for salaried and hourly employees.
  Handles base pay, overtime, commissions, bonuses, and statutory deductions
  for a standard bi-weekly payroll cycle.
  """

  require Logger

  @tax_brackets [
    {0,      10_000, 0.10},
    {10_001, 40_000, 0.22},
    {40_001, 90_000, 0.24},
    {90_001, :infinity, 0.32}
  ]
  @ss_rate              0.062
  @medicare_rate        0.0145
  @standard_work_hours  80

  @type employee :: %{
          id: String.t(),
          name: String.t(),
          employment_type: :salaried | :hourly,
          base_pay: float(),
          pay_period: :biweekly | :monthly,
          department: String.t(),
          optional(:overtime_hours) => float(),
          optional(:commission_amount) => float(),
          optional(:bonus) => float(),
          optional(:pre_tax_deductions) => float()
        }

  @spec gross_pay(employee()) :: {:ok, map()} | {:error, String.t()}
  def gross_pay(employee) do
    with {:ok, base}      <- compute_base(employee),
         {:ok, breakdown} <- compute_extras(employee, base) do
      {:ok, breakdown}
    end
  end

  defp compute_base(%{employment_type: :salaried, base_pay: pay}) do
    {:ok, Float.round(pay, 2)}
  end

  defp compute_base(%{employment_type: :hourly, base_pay: hourly_rate}) do
    {:ok, Float.round(hourly_rate * @standard_work_hours, 2)}
  end

  defp compute_base(_), do: {:error, "unknown employment type"}

  defp compute_extras(employee, base_pay) do
    overtime_hours    = employee[:overtime_hours]
    commission_amount = employee[:commission_amount]
    bonus             = employee[:bonus]

    overtime_rate = employee.base_pay * 1.5 / @standard_work_hours
    overtime_pay  = if overtime_hours, do: Float.round(overtime_hours * overtime_rate, 2), else: 0.0

    commission = commission_amount || 0.0
    bonus_pay  = bonus || 0.0

    gross = base_pay + overtime_pay + commission + bonus_pay

    breakdown = %{
      employee_id:       employee.id,
      name:              employee.name,
      department:        employee.department,
      base_pay:          base_pay,
      overtime_pay:      overtime_pay,
      commission:        commission,
      bonus:             bonus_pay,
      gross_pay:         Float.round(gross, 2)
    }

    {:ok, breakdown}
  end

  @spec net_pay(map()) :: {:ok, map()} | {:error, String.t()}
  def net_pay(%{gross_pay: gross} = breakdown) when gross < 0,
    do: {:error, "gross pay cannot be negative"}

  def net_pay(%{gross_pay: gross} = breakdown) do
    federal_tax = compute_federal_tax(gross)
    ss_tax      = Float.round(gross * @ss_rate, 2)
    medicare    = Float.round(gross * @medicare_rate, 2)
    pre_tax_ded = Map.get(breakdown, :pre_tax_deductions, 0.0)

    total_deductions = federal_tax + ss_tax + medicare + pre_tax_ded
    net = Float.round(gross - total_deductions, 2)

    result = Map.merge(breakdown, %{
      federal_tax:       federal_tax,
      social_security:   ss_tax,
      medicare:          medicare,
      pre_tax_deductions: pre_tax_ded,
      total_deductions:  Float.round(total_deductions, 2),
      net_pay:           net
    })

    {:ok, result}
  end

  defp compute_federal_tax(gross) do
    @tax_brackets
    |> Enum.reduce(0.0, fn
      {low, :infinity, rate}, acc when gross > low ->
        acc + (gross - low) * rate

      {low, high, rate}, acc when gross > low ->
        taxable = min(gross, high) - low
        acc + taxable * rate

      _, acc ->
        acc
    end)
    |> Float.round(2)
  end

  @spec pay_stub(map()) :: String.t()
  def pay_stub(net_breakdown) do
    """
    PAY STUB — #{net_breakdown.name} (#{net_breakdown.employee_id})
    Dept: #{net_breakdown.department}
    ─────────────────────────────────────────
    Base Pay:            $#{net_breakdown.base_pay}
    Overtime:            $#{net_breakdown.overtime_pay}
    Commission:          $#{net_breakdown.commission}
    Bonus:               $#{net_breakdown.bonus}
    ─────────────────────────────────────────
    Gross Pay:           $#{net_breakdown.gross_pay}
    Federal Tax:        -$#{net_breakdown.federal_tax}
    Social Security:    -$#{net_breakdown.social_security}
    Medicare:           -$#{net_breakdown.medicare}
    Pre-Tax Deductions: -$#{net_breakdown.pre_tax_deductions}
    ─────────────────────────────────────────
    NET PAY:             $#{net_breakdown.net_pay}
    """
  end
end
```
