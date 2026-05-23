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
end
```
