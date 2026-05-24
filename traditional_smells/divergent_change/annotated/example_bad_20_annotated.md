# Annotated Example — Divergent Change

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** `EmployeeService` module (entire module)
- **Affected functions:** `hire_employee/1`, `update_personal_info/2`, `record_attendance/2`, `compute_monthly_payroll/2`, `generate_payslip/2`, `schedule_shift/3`
- **Short explanation:** `EmployeeService` conflates three unrelated concerns — HR (hiring/personal info), payroll (salary computation/payslips), and scheduling (shift planning) — so it must change whenever HR policies, payroll rules, or scheduling logic evolve, for completely independent reasons.

---

```elixir
defmodule HR.EmployeeService do
  @moduledoc """
  Manages employee records, payroll computation, and shift scheduling.
  """

  require Logger

  alias HR.Repo
  alias HR.Employees.Employee
  alias HR.Attendance.Record

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because three unrelated axes of change live in
  # one module: (1) HR / personnel data, (2) payroll calculation, and
  # (3) shift scheduling. A change to tax brackets, a new attendance policy,
  # or a shift-rotation algorithm would each independently modify this module.

  ## ─────────────────────────────────────────────
  ## Reason to modify (1): HR / personnel policies
  ## ─────────────────────────────────────────────

  @doc "Onboards a new employee and persists the record."
  def hire_employee(attrs) do
    changeset = Employee.changeset(%Employee{}, attrs)

    case HR.Repo.insert(changeset) do
      {:ok, employee} ->
        Logger.info("Employee #{employee.id} hired: #{employee.full_name}")
        {:ok, employee}

      {:error, cs} ->
        {:error, cs}
    end
  end

  @doc "Updates personal information for an existing employee."
  def update_personal_info(%Employee{} = employee, attrs) do
    allowed = [:phone, :address, :emergency_contact, :bank_account]
    filtered = Map.take(attrs, allowed)

    employee
    |> Employee.changeset(filtered)
    |> Repo.update()
  end

  @doc "Records a single attendance entry for an employee."
  def record_attendance(%Employee{} = employee, %{date: date, hours: hours}) do
    changeset =
      Record.changeset(%Record{}, %{
        employee_id: employee.id,
        date: date,
        hours_worked: hours
      })

    case Repo.insert(changeset) do
      {:ok, record} ->
        Logger.debug("Attendance recorded: #{employee.id} on #{date}")
        {:ok, record}

      {:error, cs} ->
        {:error, cs}
    end
  end

  ## ─────────────────────────────────────────────
  ## Reason to modify (2): Payroll / tax rules
  ## ─────────────────────────────────────────────

  @doc "Computes the gross and net salary for an employee in a given month."
  def compute_monthly_payroll(%Employee{} = employee, year_month) do
    records = Repo.all(attendance_query(employee.id, year_month))
    total_hours = Enum.sum(Enum.map(records, & &1.hours_worked))

    gross = Decimal.mult(employee.hourly_rate, total_hours)

    tax_rate =
      cond do
        Decimal.gt?(gross, Decimal.new("10000")) -> Decimal.new("0.30")
        Decimal.gt?(gross, Decimal.new("5000")) -> Decimal.new("0.22")
        true -> Decimal.new("0.15")
      end

    tax = Decimal.mult(gross, tax_rate)
    net = Decimal.sub(gross, tax)

    %{
      employee_id: employee.id,
      period: year_month,
      total_hours: total_hours,
      gross: gross,
      tax: tax,
      net: net
    }
  end

  @doc "Produces a structured payslip map from a payroll result."
  def generate_payslip(%Employee{} = employee, payroll) do
    %{
      payslip_id: "PS-#{employee.id}-#{payroll.period}",
      issued_at: Date.utc_today(),
      employee_name: employee.full_name,
      position: employee.position,
      department: employee.department,
      period: payroll.period,
      hours_worked: payroll.total_hours,
      gross_salary: payroll.gross,
      income_tax: payroll.tax,
      net_salary: payroll.net
    }
  end

  ## ─────────────────────────────────────────────
  ## Reason to modify (3): Shift scheduling logic
  ## ─────────────────────────────────────────────

  @doc "Schedules a shift for an employee, enforcing a 8-hour minimum rest gap."
  def schedule_shift(%Employee{} = employee, date, %{start: start_time, end: end_time}) do
    last_shift = fetch_last_shift(employee.id)

    rest_hours =
      case last_shift do
        nil -> 99
        shift -> hours_between(shift.end_time, start_time)
      end

    if rest_hours < 8 do
      {:error, :insufficient_rest_period}
    else
      shift = %{
        employee_id: employee.id,
        date: date,
        start_time: start_time,
        end_time: end_time,
        duration_hours: hours_between(start_time, end_time)
      }

      Logger.info(
        "Shift scheduled for employee #{employee.id} on #{date} " <>
          "(#{start_time}–#{end_time})"
      )

      {:ok, shift}
    end
  end

  # VALIDATION: SMELL END

  ## ── Private helpers ──────────────────────

  defp attendance_query(employee_id, year_month) do
    import Ecto.Query
    from r in Record,
      where: r.employee_id == ^employee_id and fragment("DATE_TRUNC('month', ?)", r.date) == ^year_month
  end

  defp fetch_last_shift(employee_id) do
    Logger.debug("Fetching last shift for #{employee_id}")
    nil
  end

  defp hours_between(from, to) do
    Time.diff(to, from, :second) / 3600
  end
end
```
