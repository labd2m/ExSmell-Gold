```elixir
defmodule MyApp.EmployeeAdmin do
  @moduledoc """
  Provides HR administration capabilities: employee lifecycle management,
  payroll computation, and shift scheduling.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.{Employee, PayrollEntry, Shift}
  import Ecto.Query



  @doc """
  Creates an employee record from the given onboarding attributes.
  """
  def hire_employee(attrs) do
    changeset =
      %Employee{}
      |> Employee.changeset(Map.merge(attrs, %{status: :active, hired_on: Date.utc_today()}))

    case Repo.insert(changeset) do
      {:ok, employee} = result ->
        provision_system_access(employee)
        result

      error ->
        error
    end
  end

  @doc """
  Marks an employee as terminated, recording the reason and effective date.
  """
  def terminate_employee(%Employee{} = employee, reason) do
    if employee.status == :terminated do
      {:error, :already_terminated}
    else
      employee
      |> Employee.changeset(%{
        status: :terminated,
        termination_reason: reason,
        terminated_on: Date.utc_today()
      })
      |> Repo.update()
      |> case do
        {:ok, emp} = result ->
          revoke_system_access(emp)
          result

        error ->
          error
      end
    end
  end

  defp provision_system_access(%Employee{email: email, role: role}) do
    MyApp.IAM.grant_role(email, role)
  end

  defp revoke_system_access(%Employee{email: email}) do
    MyApp.IAM.revoke_all(email)
  end


  @doc """
  Computes and persists a payroll entry for an employee for the given pay period.
  """
  def compute_payroll(%Employee{} = employee, %Date.Range{} = period) do
    gross_cents = calculate_gross(employee, period)
    deductions = calculate_deductions(gross_cents, employee.tax_bracket)
    net_cents = gross_cents - deductions

    %PayrollEntry{}
    |> PayrollEntry.changeset(%{
      employee_id: employee.id,
      period_start: period.first,
      period_end: period.last,
      gross_cents: gross_cents,
      deductions_cents: deductions,
      net_cents: net_cents,
      processed_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  defp calculate_gross(%Employee{salary_cents_annual: annual}, period) do
    days = Date.diff(period.last, period.first) + 1
    round(annual / 365 * days)
  end

  defp calculate_deductions(gross, :standard), do: round(gross * 0.22)
  defp calculate_deductions(gross, :high), do: round(gross * 0.32)
  defp calculate_deductions(gross, _), do: round(gross * 0.15)

  @doc """
  Applies a percentage raise to an employee's annual salary.
  """
  def apply_raise(%Employee{} = employee, pct, effective_date) when pct > 0 do
    new_salary = round(employee.salary_cents_annual * (1 + pct / 100.0))

    employee
    |> Employee.changeset(%{
      salary_cents_annual: new_salary,
      last_raise_pct: pct,
      last_raise_date: effective_date
    })
    |> Repo.update()
  end


  @doc """
  Assigns an employee to a shift on the given date and time slot.
  """
  def assign_shift(%Employee{} = employee, date, slot) do
    if shift_conflict?(employee.id, date, slot) do
      {:error, :shift_conflict}
    else
      %Shift{}
      |> Shift.changeset(%{
        employee_id: employee.id,
        date: date,
        slot: slot,
        status: :assigned
      })
      |> Repo.insert()
    end
  end

  @doc """
  Swaps a shift between two employees, validating both sides for conflicts.
  """
  def swap_shift(%Shift{} = shift, %Employee{} = new_employee) do
    if shift_conflict?(new_employee.id, shift.date, shift.slot) do
      {:error, :shift_conflict}
    else
      shift
      |> Shift.changeset(%{employee_id: new_employee.id, swapped_at: DateTime.utc_now()})
      |> Repo.update()
    end
  end

  defp shift_conflict?(employee_id, date, slot) do
    Repo.exists?(
      from s in Shift,
        where: s.employee_id == ^employee_id and s.date == ^date and s.slot == ^slot
    )
  end

end
```
