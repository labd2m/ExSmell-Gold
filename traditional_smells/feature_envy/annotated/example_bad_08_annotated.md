# Annotated Example 08: Feature Envy

## Metadata

- **Smell**: Feature Envy
- **Expected Smell Location**: `Scheduling.ShiftPlanner.format_employee_availability/1`
- **Affected Function(s)**: `format_employee_availability/1`
- **Explanation**: `format_employee_availability/1` exclusively uses functions and data
  from the `Employee` module (`Employee.full_name/1`, `Employee.department/1`,
  `Employee.weekly_hour_limit/1`, `Employee.contracted_hours/1`,
  `Employee.certifications/1`, `Employee.availability_windows/1`,
  `Employee.preferred_shift_type/1`). `ShiftPlanner` contributes no logic of its own;
  this function only interrogates the `Employee` module.

## Code

```elixir
defmodule Scheduling.ShiftPlanner do
  alias Scheduling.{Shift, ShiftAssignment, Schedule}
  alias HR.Employee

  @doc """
  Generates a weekly shift plan for all active employees in a team.
  Eligible employees are assigned to shifts based on availability, certification, and hours.
  """
  def generate_weekly_plan(team_id, week_start) do
    employees = Employee.list_active_for_team(team_id)
    shifts = Shift.list_for_week(team_id, week_start)

    assignments =
      Enum.flat_map(shifts, fn shift ->
        eligible = Enum.filter(employees, &eligible_for_shift?(&1, shift))
        assign_employees_to_shift(shift, eligible)
      end)

    Schedule.create(%{
      team_id: team_id,
      week_start: week_start,
      assignments: assignments
    })
  end

  @doc """
  Returns all shifts for the given week that have not yet been fully staffed.
  """
  def list_unassigned_shifts(team_id, week_start) do
    Shift.list_unassigned(team_id, week_start)
  end

  @doc """
  Returns a coverage summary for a team's week, including over- and under-staffed shifts.
  """
  def coverage_report(team_id, week_start) do
    Shift.coverage_summary(team_id, week_start)
  end

  @doc """
  Builds a structured availability card for a single employee,
  used in the planning dashboard.
  """
  def build_employee_card(employee_id) do
    employee = Employee.get!(employee_id)
    format_employee_availability(employee)
  end

  @doc """
  Returns availability cards for all active employees in a team.
  """
  def team_availability_cards(team_id) do
    team_id
    |> Employee.list_active_for_team()
    |> Enum.map(&format_employee_availability/1)
  end

  defp eligible_for_shift?(employee, shift) do
    available = Employee.available_on?(employee, shift.date)
    certified = Employee.has_certification?(employee, shift.required_certification)
    not_overtime = not Employee.would_exceed_weekly_hours?(employee, shift.duration_hours)

    available and certified and not_overtime
  end

  defp assign_employees_to_shift(shift, employees) do
    employees
    |> Enum.take(shift.required_headcount)
    |> Enum.map(fn employee ->
      ShiftAssignment.create(%{
        shift_id: shift.id,
        employee_id: employee.id,
        assigned_at: DateTime.utc_now()
      })
    end)
  end

  # VALIDATION: SMELL START - Feature Envy
  # VALIDATION: This is a smell because format_employee_availability/1 exclusively uses
  # VALIDATION: functions and data from the Employee module: Employee.full_name/1,
  # VALIDATION: Employee.department/1, Employee.weekly_hour_limit/1,
  # VALIDATION: Employee.contracted_hours/1, Employee.certifications/1,
  # VALIDATION: Employee.availability_windows/1, and Employee.preferred_shift_type/1.
  # VALIDATION: ShiftPlanner contributes no logic of its own to this function;
  # VALIDATION: it only interrogates Employee data, making it a better fit in that module.
  defp format_employee_availability(employee) do
    full_name = Employee.full_name(employee)
    department = Employee.department(employee)
    hour_limit = Employee.weekly_hour_limit(employee)
    contracted = Employee.contracted_hours(employee)
    certifications = Employee.certifications(employee)
    availability = Employee.availability_windows(employee)
    preferred_shift = Employee.preferred_shift_type(employee)

    %{
      id: employee.id,
      name: full_name,
      department: department,
      weekly_hour_limit: hour_limit,
      contracted_hours: contracted,
      certifications: certifications,
      availability: availability,
      preferred_shift: preferred_shift
    }
  end
  # VALIDATION: SMELL END
end
```
