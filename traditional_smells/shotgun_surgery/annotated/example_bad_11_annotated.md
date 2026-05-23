# Example Bad 11 — Annotated

## Metadata

- **Smell Name**: Shotgun Surgery
- **Expected Smell Location**: Functions `calculate_gross_salary/2`, `get_benefit_multiplier/1`, `get_annual_leave_days/1`, and `compute_overtime_rate/1` inside `HR.CompensationCalculator`
- **Affected Functions**: `calculate_gross_salary/2`, `get_benefit_multiplier/1`, `get_annual_leave_days/1`, `compute_overtime_rate/1`
- **Explanation**: The employment type logic (`:full_time`, `:part_time`, `:contractor`) is spread across four separate functions. Adding a new employment type (e.g., `:intern`) demands four independent changes across the module, a classic case of Shotgun Surgery.

```elixir
defmodule HR.CompensationCalculator do
  @moduledoc """
  Calculates compensation packages for employees based on their employment type.
  Handles gross salary, benefits, annual leave entitlements,
  and overtime rates for different categories of workers.
  """

  alias HR.{Employee, PayrollLedger, BenefitsRegistry, LeaveBalance, PayrollAudit}

  @working_hours_per_month 160
  @overtime_threshold_hours 8

  def process_payroll(%Employee{} = employee, hours_worked, period) do
    with {:ok, gross}    <- compute_gross(employee, hours_worked),
         {:ok, benefits} <- compute_benefits(employee, gross),
         {:ok, net}      <- compute_net(gross, benefits, employee),
         {:ok, entry}    <- PayrollLedger.record(employee, net, period) do
      PayrollAudit.log(entry)
      {:ok, entry}
    end
  end

  defp compute_gross(employee, hours_worked) do
    gross = calculate_gross_salary(employee, hours_worked)
    {:ok, gross}
  end

  defp compute_benefits(employee, gross) do
    multiplier = get_benefit_multiplier(employee.employment_type)
    benefits   = Float.round(gross * multiplier, 2)
    {:ok, benefits}
  end

  defp compute_net(gross, benefits, employee) do
    deductions = BenefitsRegistry.get_deductions(employee.id)
    net        = gross + benefits - deductions
    {:ok, Float.round(net, 2)}
  end

  # VALIDATION: SMELL START - Shotgun Surgery [location 1 of 4]
  # VALIDATION: This is a smell because adding a new employment type (e.g., :intern)
  # requires a new clause here AND in get_benefit_multiplier/1, get_annual_leave_days/1,
  # and compute_overtime_rate/1 — four scattered changes for one new type.
  def calculate_gross_salary(%Employee{employment_type: :full_time, base_salary: salary}, _hours) do
    salary / 12
  end

  def calculate_gross_salary(%Employee{employment_type: :part_time, hourly_rate: rate}, hours_worked) do
    overtime_hours = max(0, hours_worked - @overtime_threshold_hours * 20)
    regular_hours  = hours_worked - overtime_hours
    regular_pay    = regular_hours * rate
    overtime_pay   = overtime_hours * rate * compute_overtime_rate(:part_time)
    Float.round(regular_pay + overtime_pay, 2)
  end

  def calculate_gross_salary(%Employee{employment_type: :contractor, hourly_rate: rate}, hours_worked) do
    Float.round(hours_worked * rate, 2)
  end

  def calculate_gross_salary(%Employee{base_salary: salary}, _hours) do
    salary / 12
  end
  # VALIDATION: SMELL END [location 1 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 2 of 4]
  # VALIDATION: This is a smell because a new employment type also requires a new
  # benefit multiplier clause here, independent of calculate_gross_salary/2.
  def get_benefit_multiplier(:full_time),  do: 0.25
  def get_benefit_multiplier(:part_time),  do: 0.10
  def get_benefit_multiplier(:contractor), do: 0.00
  def get_benefit_multiplier(_),           do: 0.05
  # VALIDATION: SMELL END [location 2 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 3 of 4]
  # VALIDATION: This is a smell because a new employment type also requires a new
  # leave entitlement clause here, independent of the previous two locations.
  def get_annual_leave_days(:full_time),  do: 25
  def get_annual_leave_days(:part_time),  do: 12
  def get_annual_leave_days(:contractor), do: 0
  def get_annual_leave_days(_),           do: 5
  # VALIDATION: SMELL END [location 3 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 4 of 4]
  # VALIDATION: This is a smell because a new employment type also requires a new
  # overtime rate clause here, completing the four-location change.
  def compute_overtime_rate(:full_time),  do: 1.5
  def compute_overtime_rate(:part_time),  do: 1.25
  def compute_overtime_rate(:contractor), do: 1.0
  def compute_overtime_rate(_),           do: 1.0
  # VALIDATION: SMELL END [location 4 of 4]

  def initialize_leave_balance(%Employee{} = employee) do
    days = get_annual_leave_days(employee.employment_type)
    LeaveBalance.create(employee.id, days)
  end

  def validate_hours_submission(%Employee{employment_type: :full_time}, _hours), do: :ok

  def validate_hours_submission(%Employee{employment_type: type}, hours)
    when type in [:part_time, :contractor] do
    if hours > @working_hours_per_month do
      {:error, :exceeds_monthly_maximum}
    else
      :ok
    end
  end

  def validate_hours_submission(_, _), do: :ok

  def summarize_compensation(%Employee{} = employee) do
    %{
      employment_type:   employee.employment_type,
      benefit_pct:       get_benefit_multiplier(employee.employment_type) * 100,
      leave_days:        get_annual_leave_days(employee.employment_type),
      overtime_rate:     compute_overtime_rate(employee.employment_type)
    }
  end
end
```
