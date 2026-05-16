# Annotated Example 23

## Metadata

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Payroll.SalaryCalculator.compute/2`, lines where `employee` map keys are accessed dynamically
- **Affected function(s):** `compute/2`
- **Short explanation:** `employee[:base_salary]`, `employee[:overtime_hours]`, `employee[:bonus]`, and `employee[:tax_class]` use dynamic bracket access. When `:base_salary` is absent, `nil` flows into arithmetic operations (`nil * rate`), crashing at runtime. A missing `:tax_class` silently selects the wrong tax bracket rather than indicating a data integrity problem.

---

```elixir
defmodule Payroll.SalaryCalculator do
  @moduledoc """
  Computes net salary for employees, applying overtime, bonuses, and
  tax withholding according to their employment contract and tax class.
  """

  require Logger

  @overtime_multiplier 1.5
  @social_security_rate 0.11

  @tax_brackets %{
    1 => 0.00,
    2 => 0.07,
    3 => 0.15,
    4 => 0.22,
    5 => 0.275
  }

  @type payslip :: %{
          employee_id: String.t(),
          gross_salary: float(),
          overtime_pay: float(),
          bonus: float(),
          social_security: float(),
          income_tax: float(),
          net_salary: float(),
          period: String.t(),
          computed_at: DateTime.t()
        }

  @spec compute(map(), map()) :: {:ok, payslip()} | {:error, String.t()}
  def compute(employee, period_config) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `employee[:base_salary]`,
    # `employee[:overtime_hours]`, `employee[:bonus]`, and
    # `employee[:tax_class]` use dynamic bracket access on a plain map.
    # When `:base_salary` is absent, `nil` is returned and later multiplied
    # inside `compute_gross/2` (`nil * 1`), immediately raising
    # `ArithmeticError`. When `:tax_class` is absent, `Map.get/3` on
    # `@tax_brackets` returns the default rate (0.00) instead of surfacing
    # the missing classification, silently producing a zero-tax payslip.
    base_salary    = employee[:base_salary]
    overtime_hours = employee[:overtime_hours]
    bonus          = employee[:bonus]
    tax_class      = employee[:tax_class]
    # VALIDATION: SMELL END

    period = Map.get(period_config, :label, "unknown")

    with :ok <- validate_base_salary(base_salary),
         :ok <- validate_tax_class(tax_class) do
      hourly_rate   = base_salary / Map.get(period_config, :standard_hours, 160)
      overtime_pay  = compute_overtime(overtime_hours, hourly_rate)
      effective_bonus = bonus || 0.0
      gross         = compute_gross(base_salary, overtime_pay, effective_bonus)

      social_security = Float.round(gross * @social_security_rate, 2)
      income_tax      = compute_income_tax(gross, tax_class)
      net             = Float.round(gross - social_security - income_tax, 2)

      payslip = %{
        employee_id: Map.get(employee, :id),
        gross_salary: gross,
        overtime_pay: overtime_pay,
        bonus: effective_bonus,
        social_security: social_security,
        income_tax: income_tax,
        net_salary: net,
        period: period,
        computed_at: DateTime.utc_now()
      }

      Logger.info("Payslip computed",
        employee_id: payslip.employee_id,
        period: period,
        gross: gross,
        net: net
      )

      {:ok, payslip}
    end
  end

  # ── Computation ─────────────────────────────────────────────────────────────

  defp compute_overtime(nil, _rate), do: 0.0

  defp compute_overtime(hours, rate) when is_number(hours) and hours > 0 do
    Float.round(hours * rate * @overtime_multiplier, 2)
  end

  defp compute_overtime(_, _), do: 0.0

  defp compute_gross(base, overtime, bonus) do
    Float.round(base + overtime + bonus, 2)
  end

  defp compute_income_tax(gross, tax_class) do
    rate = Map.get(@tax_brackets, tax_class, 0.00)
    Float.round(gross * rate, 2)
  end

  # ── Validators ──────────────────────────────────────────────────────────────

  defp validate_base_salary(nil), do: {:error, "Base salary is required"}

  defp validate_base_salary(s) when is_number(s) and s >= 0, do: :ok

  defp validate_base_salary(s),
    do: {:error, "Base salary must be a non-negative number, got: #{inspect(s)}"}

  defp validate_tax_class(nil), do: {:error, "Tax class is required"}

  defp validate_tax_class(c) when c in 1..5, do: :ok

  defp validate_tax_class(c),
    do: {:error, "Tax class must be between 1 and 5, got: #{inspect(c)}"}
end
```
