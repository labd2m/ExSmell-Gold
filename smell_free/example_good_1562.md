```elixir
defmodule Workforce.Scheduling.ShiftPlanner do
  @moduledoc """
  Computes optimal shift assignments for workforce scheduling.

  Resolves employee availability, role requirements, and coverage constraints
  to produce valid shift assignment maps for a given scheduling window.
  """

  alias Workforce.Scheduling.{Employee, Shift, Coverage, RoleRequirement}

  @type assignment :: %{shift_id: String.t(), employee_id: String.t(), role: atom()}

  @type plan_result ::
          {:ok, [assignment()]}
          | {:error, :insufficient_coverage, [Shift.t()]}
          | {:error, :no_eligible_employees, Shift.t()}

  @doc """
  Generates a shift assignment plan for the given shifts and employee pool.

  Returns `{:ok, assignments}` if all shifts can be covered, or an error
  identifying the uncoverable shifts or roles.
  """
  @spec plan([Shift.t()], [Employee.t()], Coverage.t()) :: plan_result()
  def plan(shifts, employees, %Coverage{} = coverage) do
    availability_index = build_availability_index(employees)

    shifts
    |> Enum.sort_by(&shift_priority/1, :desc)
    |> assign_shifts(availability_index, coverage, [])
  end

  defp assign_shifts([], _index, _coverage, assignments), do: {:ok, Enum.reverse(assignments)}

  defp assign_shifts([shift | rest], availability_index, coverage, assignments) do
    required_roles = Coverage.roles_for_shift(coverage, shift)

    case assign_roles(shift, required_roles, availability_index, []) do
      {:ok, role_assignments, updated_index} ->
        assign_shifts(rest, updated_index, coverage, role_assignments ++ assignments)

      {:error, :no_eligible_employees} ->
        {:error, :no_eligible_employees, shift}
    end
  end

  defp assign_roles(_shift, [], index, role_assignments), do: {:ok, role_assignments, index}

  defp assign_roles(shift, [%RoleRequirement{role: role} | rest], index, acc) do
    case find_eligible_employee(shift, role, index) do
      {:ok, employee_id, updated_index} ->
        assignment = %{shift_id: shift.id, employee_id: employee_id, role: role}
        assign_roles(shift, rest, updated_index, [assignment | acc])

      :error ->
        {:error, :no_eligible_employees}
    end
  end

  defp find_eligible_employee(shift, role, availability_index) do
    result =
      availability_index
      |> Enum.find(fn {_emp_id, info} ->
        role in info.roles and shift_available?(shift, info.busy_windows)
      end)

    case result do
      {employee_id, info} ->
        updated_info = %{info | busy_windows: [shift_window(shift) | info.busy_windows]}
        updated_index = Map.put(availability_index, employee_id, updated_info)
        {:ok, employee_id, updated_index}

      nil ->
        :error
    end
  end

  defp shift_available?(%Shift{start_time: start, end_time: finish}, busy_windows) do
    Enum.all?(busy_windows, fn {busy_start, busy_end} ->
      DateTime.compare(finish, busy_start) != :gt or
        DateTime.compare(start, busy_end) != :lt
    end)
  end

  defp shift_window(%Shift{start_time: start, end_time: finish}), do: {start, finish}

  defp build_availability_index(employees) do
    Map.new(employees, fn employee ->
      {employee.id, %{roles: employee.roles, busy_windows: []}}
    end)
  end

  defp shift_priority(%Shift{priority: priority}), do: priority
  defp shift_priority(%Shift{}), do: 0
end
```
