# Annotated Example – Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `HR.Payroll.calculate_gross_pay/1` and `HR.Payroll.calculate_overtime_pay/1` |
| **Affected functions** | `calculate_gross_pay/1`, `calculate_overtime_pay/1` |
| **Short explanation** | Both functions duplicate the logic for determining an employee's effective hourly rate: fetching the employee's compensation record, converting an annual salary to hourly, or using a stored hourly rate. If salary-to-hourly conversion changes (e.g., a different divisor), it must be updated in two places. |

```elixir
defmodule HR.Payroll do
  @moduledoc """
  Handles payroll calculations for hourly and salaried employees,
  including regular pay, overtime, and deductions.
  """

  alias HR.Repo
  alias HR.Employee
  alias HR.CompensationRecord
  alias HR.PayPeriod

  @annual_hours 2080
  @overtime_multiplier 1.5

  @doc """
  Calculates gross pay for an employee for a given pay period.
  Returns the total amount in USD as a float.
  """
  def calculate_gross_pay(%Employee{} = employee, %PayPeriod{} = pay_period) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the effective hourly rate derivation
    # (fetching the compensation record, branching on pay_type, converting
    # annual salary using @annual_hours) is duplicated in calculate_overtime_pay/1.
    # If the annual hours divisor changes, both functions must be updated.
    compensation = Repo.get_by!(CompensationRecord, employee_id: employee.id, active: true)

    hourly_rate =
      case compensation.pay_type do
        :hourly -> compensation.rate
        :salary -> compensation.annual_salary / @annual_hours
      end
    # VALIDATION: SMELL END

    gross = hourly_rate * pay_period.regular_hours
    Float.round(gross, 2)
  end

  @doc """
  Calculates the overtime pay owed to an employee for a given pay period.
  Returns the overtime pay amount in USD.
  """
  def calculate_overtime_pay(%Employee{} = employee, %PayPeriod{} = pay_period) do
    if pay_period.overtime_hours <= 0 do
      0.0
    else
      # VALIDATION: SMELL START - Duplicated Code
      # VALIDATION: This is a smell because this hourly rate derivation block
      # is a copy of the one in calculate_gross_pay/1.
      compensation = Repo.get_by!(CompensationRecord, employee_id: employee.id, active: true)

      hourly_rate =
        case compensation.pay_type do
          :hourly -> compensation.rate
          :salary -> compensation.annual_salary / @annual_hours
        end
      # VALIDATION: SMELL END

      overtime_pay = hourly_rate * @overtime_multiplier * pay_period.overtime_hours
      Float.round(overtime_pay, 2)
    end
  end

  @doc """
  Calculates total net pay for an employee after deductions.
  """
  def calculate_net_pay(%Employee{} = employee, %PayPeriod{} = pay_period) do
    gross = calculate_gross_pay(employee, pay_period)
    overtime = calculate_overtime_pay(employee, pay_period)
    total_gross = gross + overtime

    deductions = total_gross * deduction_rate(employee)
    net = total_gross - deductions

    %{
      gross_pay: total_gross,
      deductions: Float.round(deductions, 2),
      net_pay: Float.round(net, 2),
      period: pay_period.label
    }
  end

  @doc """
  Generates a pay summary for all active employees in a pay period.
  """
  def payroll_run(%PayPeriod{} = pay_period) do
    Repo.all_by(Employee, status: :active)
    |> Enum.map(fn emp -> {emp.id, calculate_net_pay(emp, pay_period)} end)
    |> Map.new()
  end

  defp deduction_rate(%Employee{tax_bracket: bracket}) do
    case bracket do
      :low -> 0.18
      :mid -> 0.24
      :high -> 0.32
      _ -> 0.22
    end
  end
end
```
