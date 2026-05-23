```elixir
defmodule Payroll.WageCalculator do
  @moduledoc """
  Computes gross pay for employees based on their contract type,
  hours worked, and applicable overtime or day-rate rules.
  """


  @spec calculate_gross(atom(), map()) :: float()
  def calculate_gross(:full_time, %{hours_worked: hours, hourly_rate: rate}) do
    regular = min(hours, 40) * rate
    overtime = max(hours - 40, 0) * rate * 1.5
    regular + overtime
  end

  def calculate_gross(:part_time, %{hours_worked: hours, hourly_rate: rate}) do
    hours * rate
  end

  def calculate_gross(:contractor, %{days_worked: days, day_rate: rate}) do
    days * rate
  end

  @spec overtime_eligible?(atom()) :: boolean()
  def overtime_eligible?(:full_time),  do: true
  def overtime_eligible?(:part_time),  do: false
  def overtime_eligible?(:contractor), do: false

  @spec payment_frequency(atom()) :: atom()
  def payment_frequency(:full_time),  do: :biweekly
  def payment_frequency(:part_time),  do: :biweekly
  def payment_frequency(:contractor), do: :monthly


  def process_payroll(employee, period) do
    gross = calculate_gross(employee.contract_type, period)
    deductions = Payroll.DeductionEngine.calculate(employee, gross)

    %{
      employee_id:     employee.id,
      period:          period.label,
      gross:           Float.round(gross, 2),
      deductions:      deductions,
      net:             Float.round(gross - deductions, 2),
      payment_schedule: payment_frequency(employee.contract_type)
    }
  end
end

defmodule Payroll.BenefitsPolicy do
  @moduledoc """
  Determines leave entitlements and health benefit eligibility for employees
  based on their employment contract classification.
  """


  @spec entitled_days(atom()) :: non_neg_integer()
  def entitled_days(:full_time),  do: 20
  def entitled_days(:part_time),  do: 10
  def entitled_days(:contractor), do: 0

  @spec includes_health_plan?(atom()) :: boolean()
  def includes_health_plan?(:full_time),  do: true
  def includes_health_plan?(:part_time),  do: false
  def includes_health_plan?(:contractor), do: false


  def annual_benefits_summary(employee) do
    type = employee.contract_type

    %{
      employee_id:      employee.id,
      contract_type:    type,
      annual_leave_days: entitled_days(type),
      health_plan:      includes_health_plan?(type),
      pension_scheme:   type == :full_time
    }
  end

  def leave_balance(employee) do
    used = employee.leave_taken_days
    total = entitled_days(employee.contract_type)
    max(total - used, 0)
  end
end

defmodule Payroll.ComplianceChecker do
  @moduledoc """
  Validates that employee schedules and payroll records adhere to
  labour law requirements for each contract classification.
  """


  @spec max_hours_per_week(atom()) :: pos_integer()
  def max_hours_per_week(:full_time),  do: 48
  def max_hours_per_week(:part_time),  do: 30
  def max_hours_per_week(:contractor), do: 60

  @spec minimum_notice_days(atom()) :: non_neg_integer()
  def minimum_notice_days(:full_time),  do: 30
  def minimum_notice_days(:part_time),  do: 14
  def minimum_notice_days(:contractor), do: 0


  def validate_schedule(employee, schedule) do
    weekly_hours = Enum.sum(Enum.map(schedule.shifts, & &1.duration_hours))
    max_allowed  = max_hours_per_week(employee.contract_type)

    if weekly_hours > max_allowed do
      {:error, {:hours_exceeded, %{actual: weekly_hours, max: max_allowed}}}
    else
      :ok
    end
  end

  def validate_termination_notice(employee, notice_date, termination_date) do
    notice_days  = Date.diff(termination_date, notice_date)
    min_required = minimum_notice_days(employee.contract_type)

    if notice_days >= min_required do
      :ok
    else
      {:error, {:insufficient_notice, %{given: notice_days, required: min_required}}}
    end
  end
end
```
