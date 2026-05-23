# Annotated Example – Bad Code (Feature Envy)

## Metadata

| Field | Value |
|---|---|
| **Smell** | Feature Envy |
| **Expected Smell Location** | `Payroll.SalaryComputer.compute_net_salary/1` |
| **Affected Function(s)** | `compute_net_salary/1` |
| **Explanation** | `compute_net_salary/1` is placed in `Payroll.SalaryComputer` but derives every value from `Payroll.EmployeeContract` — calling `get!/1`, `gross_salary/1`, `tax_bracket/1`, `pension_rate/1`, `has_health_deduction?/1`, and `overtime_bonus/1`. The function should belong to `EmployeeContract`. |

```elixir
defmodule Payroll.EmployeeContract do
  @moduledoc "Represents an employee's active payroll contract."

  defstruct [
    :id,
    :employee_id,
    :department,
    :base_salary,
    :currency,
    :pay_frequency,
    :overtime_hours,
    :overtime_rate,
    :tax_code,
    :pension_tier,
    :health_plan,
    :contract_start,
    :contract_end
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      employee_id: "EMP-4421",
      department: :engineering,
      base_salary: Decimal.new("85000.00"),
      currency: "USD",
      pay_frequency: :monthly,
      overtime_hours: 10,
      overtime_rate: Decimal.new("55.00"),
      tax_code: "TX_BAND_2",
      pension_tier: :tier_2,
      health_plan: :premium,
      contract_start: ~D[2022-06-01],
      contract_end: nil
    }
  end

  def gross_salary(%__MODULE__{base_salary: base, pay_frequency: :monthly}) do
    Decimal.div(base, Decimal.new("12"))
  end
  def gross_salary(%__MODULE__{base_salary: base}), do: base

  def tax_bracket(%__MODULE__{tax_code: "TX_BAND_1"}), do: Decimal.new("0.20")
  def tax_bracket(%__MODULE__{tax_code: "TX_BAND_2"}), do: Decimal.new("0.28")
  def tax_bracket(%__MODULE__{tax_code: "TX_BAND_3"}), do: Decimal.new("0.35")
  def tax_bracket(_), do: Decimal.new("0.25")

  def pension_rate(%__MODULE__{pension_tier: :tier_1}), do: Decimal.new("0.03")
  def pension_rate(%__MODULE__{pension_tier: :tier_2}), do: Decimal.new("0.05")
  def pension_rate(%__MODULE__{pension_tier: :tier_3}), do: Decimal.new("0.08")
  def pension_rate(_), do: Decimal.new("0.00")

  def has_health_deduction?(%__MODULE__{health_plan: :premium}), do: true
  def has_health_deduction?(%__MODULE__{health_plan: :standard}), do: true
  def has_health_deduction?(_), do: false

  def health_deduction_amount(%__MODULE__{health_plan: :premium}), do: Decimal.new("350.00")
  def health_deduction_amount(%__MODULE__{health_plan: :standard}), do: Decimal.new("150.00")
  def health_deduction_amount(_), do: Decimal.new("0.00")

  def overtime_bonus(%__MODULE__{overtime_hours: hrs, overtime_rate: rate}) do
    Decimal.mult(Decimal.new(hrs), rate)
  end
end

defmodule Payroll.PaySlip do
  @moduledoc "A generated pay slip record."

  defstruct [:contract_id, :period, :gross, :tax, :pension, :health, :overtime, :net, :currency]
end

defmodule Payroll.SalaryComputer do
  @moduledoc """
  Computes net salary figures and produces pay slips for a given payroll period.
  """

  alias Payroll.{EmployeeContract, PaySlip}
  require Logger

  @doc """
  Generates pay slips for all contract IDs in the given period.
  """
  def run_payroll(contract_ids, period) do
    Enum.map(contract_ids, fn id ->
      net = compute_net_salary(id)
      contract = EmployeeContract.get!(id)

      Logger.info("Pay slip generated for #{contract.employee_id}: net #{net} #{contract.currency}")

      %PaySlip{
        contract_id: id,
        period:      period,
        gross:       EmployeeContract.gross_salary(contract),
        net:         net,
        currency:    contract.currency
      }
    end)
  end

  # VALIDATION: SMELL START - Feature Envy
  # VALIDATION: This is a smell because `compute_net_salary/1` is defined in
  # VALIDATION: `Payroll.SalaryComputer` yet all its operations are on
  # VALIDATION: `Payroll.EmployeeContract`: it calls `EmployeeContract.get!/1`,
  # VALIDATION: `EmployeeContract.gross_salary/1`, `EmployeeContract.tax_bracket/1`,
  # VALIDATION: `EmployeeContract.pension_rate/1`, `EmployeeContract.has_health_deduction?/1`,
  # VALIDATION: `EmployeeContract.health_deduction_amount/1`, and
  # VALIDATION: `EmployeeContract.overtime_bonus/1`. It should live in `EmployeeContract`.
  defp compute_net_salary(contract_id) do
    contract  = EmployeeContract.get!(contract_id)
    gross     = EmployeeContract.gross_salary(contract)
    tax_rate  = EmployeeContract.tax_bracket(contract)
    pension   = EmployeeContract.pension_rate(contract)
    overtime  = EmployeeContract.overtime_bonus(contract)

    gross_with_overtime = Decimal.add(gross, overtime)

    tax_amount     = Decimal.mult(gross_with_overtime, tax_rate)
    pension_amount = Decimal.mult(gross_with_overtime, pension)

    health_amount =
      if EmployeeContract.has_health_deduction?(contract) do
        EmployeeContract.health_deduction_amount(contract)
      else
        Decimal.new("0.00")
      end

    gross_with_overtime
    |> Decimal.sub(tax_amount)
    |> Decimal.sub(pension_amount)
    |> Decimal.sub(health_amount)
    |> Decimal.round(2)
  end
  # VALIDATION: SMELL END
end
```
