# Annotated Example — Divergent Change

| Field | Value |
|---|---|
| **Smell name** | Divergent Change |
| **Expected smell location** | `EmployeeManager` module |
| **Affected functions** | `hire_employee/1`, `terminate_employee/2`, `update_position/2` (HR/personnel reason) and `calculate_payroll/1`, `apply_raise/2`, `disburse_salary/1` (payroll reason) and `assign_shift/2`, `swap_shift/3`, `get_schedule/2` (scheduling reason) |
| **Explanation** | The module mixes HR record management, payroll computation/disbursement, and shift scheduling — three separate concerns. HR policy changes, payroll regulation updates, or scheduling algorithm changes would each independently require modifications to this module. |

```elixir
defmodule HumanResources.EmployeeManager do
  @moduledoc """
  Provides operations for employee lifecycle, payroll processing, and shift scheduling.
  """

  alias HumanResources.Repo
  alias HumanResources.Employees.Employee
  alias HumanResources.Payroll.PayrollRecord
  alias HumanResources.Scheduling.Shift
  alias HumanResources.Payments.Disburser

  import Ecto.Query
  require Logger

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module has three distinct, unrelated
  # reasons to change: (1) HR and personnel lifecycle rules, (2) payroll
  # calculation and disbursement policies, and (3) shift assignment and scheduling
  # logic. Each concern has its own domain experts and change cadence.

  ## ── HR / Personnel Management ────────────────────────────────────────────────

  @doc "Onboards a new employee and creates their personnel record."
  @spec hire_employee(map()) :: {:ok, Employee.t()} | {:error, Ecto.Changeset.t()}
  def hire_employee(attrs) do
    %Employee{}
    |> Employee.changeset(
      Map.merge(attrs, %{status: :active, hire_date: Date.utc_today()})
    )
    |> Repo.insert()
  end

  @doc "Terminates an employee's record with a reason and effective date."
  @spec terminate_employee(Employee.t(), map()) ::
          {:ok, Employee.t()} | {:error, Ecto.Changeset.t()}
  def terminate_employee(%Employee{} = employee, %{reason: reason, effective_date: date}) do
    employee
    |> Employee.changeset(%{
      status: :terminated,
      termination_reason: reason,
      termination_date: date
    })
    |> Repo.update()
  end

  @doc "Updates an employee's job title and department."
  @spec update_position(Employee.t(), map()) ::
          {:ok, Employee.t()} | {:error, Ecto.Changeset.t()}
  def update_position(%Employee{} = employee, %{title: title, department_id: dept_id}) do
    employee
    |> Employee.changeset(%{
      job_title: title,
      department_id: dept_id,
      position_updated_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  ## ── Payroll Processing ───────────────────────────────────────────────────────

  @doc "Calculates the net pay for an employee for the given pay period."
  @spec calculate_payroll(Employee.t()) :: {:ok, map()} | {:error, String.t()}
  def calculate_payroll(%Employee{salary_cents: salary, tax_bracket: bracket}) do
    tax_rate = tax_rate_for_bracket(bracket)
    gross = salary
    deductions = round(gross * tax_rate)
    net = gross - deductions

    {:ok, %{gross_cents: gross, deductions_cents: deductions, net_cents: net}}
  end

  @doc "Applies a salary raise to an employee (amount in cents)."
  @spec apply_raise(Employee.t(), pos_integer()) ::
          {:ok, Employee.t()} | {:error, Ecto.Changeset.t()}
  def apply_raise(%Employee{salary_cents: current} = employee, raise_cents)
      when is_integer(raise_cents) and raise_cents > 0 do
    employee
    |> Employee.changeset(%{
      salary_cents: current + raise_cents,
      last_raise_date: Date.utc_today()
    })
    |> Repo.update()
  end

  @doc "Disburses salary payment for a pay period via the payment provider."
  @spec disburse_salary(Employee.t()) :: {:ok, map()} | {:error, term()}
  def disburse_salary(%Employee{id: id, bank_account_ref: account} = employee) do
    with {:ok, %{net_cents: net}} <- calculate_payroll(employee),
         {:ok, result} <-
           Disburser.transfer(%{
             recipient_account: account,
             amount_cents: net,
             reference: "SALARY-#{id}-#{Date.utc_today()}"
           }) do
      record = %{
        employee_id: id,
        amount_cents: net,
        paid_at: DateTime.utc_now(),
        reference: result.transaction_id
      }

      %PayrollRecord{} |> PayrollRecord.changeset(record) |> Repo.insert()
    end
  end

  ## ── Shift Scheduling ─────────────────────────────────────────────────────────

  @doc "Assigns an employee to a specific shift."
  @spec assign_shift(Employee.t(), map()) :: {:ok, Shift.t()} | {:error, term()}
  def assign_shift(%Employee{id: emp_id}, shift_attrs) do
    attrs = Map.put(shift_attrs, :employee_id, emp_id)

    case check_schedule_conflict(emp_id, shift_attrs[:start_time], shift_attrs[:end_time]) do
      :ok ->
        %Shift{} |> Shift.changeset(attrs) |> Repo.insert()

      {:error, :conflict} ->
        {:error, :schedule_conflict}
    end
  end

  @doc "Swaps a shift between two employees if both are available."
  @spec swap_shift(Shift.t(), Employee.t(), Employee.t()) ::
          {:ok, {Shift.t(), Shift.t()}} | {:error, atom()}
  def swap_shift(%Shift{} = shift, %Employee{id: from_id}, %Employee{id: to_id}) do
    Repo.transaction(fn ->
      {:ok, updated_original} =
        shift |> Shift.changeset(%{employee_id: to_id}) |> Repo.update()

      target_shift =
        Shift |> where([s], s.employee_id == ^to_id and s.start_time == ^shift.start_time) |> Repo.one()

      {:ok, updated_target} =
        target_shift |> Shift.changeset(%{employee_id: from_id}) |> Repo.update()

      {updated_original, updated_target}
    end)
  end

  @doc "Returns all shifts for an employee within the given date range."
  @spec get_schedule(Employee.t(), {Date.t(), Date.t()}) :: [Shift.t()]
  def get_schedule(%Employee{id: emp_id}, {from, to}) do
    Shift
    |> where([s], s.employee_id == ^emp_id and s.start_time >= ^from and s.end_time <= ^to)
    |> order_by([s], asc: s.start_time)
    |> Repo.all()
  end

  ## ── Private Helpers ──────────────────────────────────────────────────────────

  defp tax_rate_for_bracket(:low), do: 0.15
  defp tax_rate_for_bracket(:medium), do: 0.22
  defp tax_rate_for_bracket(:high), do: 0.32
  defp tax_rate_for_bracket(_), do: 0.22

  defp check_schedule_conflict(emp_id, start_time, end_time) do
    existing =
      Shift
      |> where(
        [s],
        s.employee_id == ^emp_id and s.start_time < ^end_time and s.end_time > ^start_time
      )
      |> Repo.exists?()

    if existing, do: {:error, :conflict}, else: :ok
  end

  # VALIDATION: SMELL END
end
```
