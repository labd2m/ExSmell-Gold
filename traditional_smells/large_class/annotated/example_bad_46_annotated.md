# Annotated Example — Large Module

- **Smell name:** Large Class (Large Module)
- **Expected smell location:** The entire `EmployeeManagement` module
- **Affected functions:** `onboard_employee/1`, `update_employee/2`, `terminate_employee/2`, `record_leave_request/2`, `approve_leave/2`, `reject_leave/2`, `calculate_payroll/2`, `generate_payslip/2`, `track_performance_review/2`, `export_headcount_report/1`
- **Short explanation:** `EmployeeManagement` covers HR onboarding/termination, leave request workflows, payroll calculation, payslip generation, performance reviews, and headcount reporting — five distinct HR sub-domains (People Ops, Leave Management, Payroll, Performance, Reporting) collapsed into a single oversized module.

```elixir
# VALIDATION: SMELL START - Large Class (Large Module)
# VALIDATION: This is a smell because EmployeeManagement handles employee
# onboarding and termination, leave request lifecycle, payroll computation,
# payslip document generation, performance review tracking, and headcount CSV
# reporting — five unrelated HR subdomain concerns that should each live in a
# dedicated focused module.
defmodule EmployeeManagement do
  @moduledoc """
  Consolidated HR module: employee onboarding/termination, leave management,
  payroll calculation, payslip generation, performance reviews, and headcount
  reporting.
  """

  require Logger
  import Ecto.Query
  alias HR.Repo
  alias HR.Employee
  alias HR.LeaveRequest
  alias HR.PayrollEntry
  alias HR.PerformanceReview

  @working_days_per_month 22
  @annual_leave_days 20

  # --- Onboarding ---

  def onboard_employee(attrs) do
    changeset =
      Employee.changeset(%Employee{}, %{
        first_name: attrs[:first_name],
        last_name: attrs[:last_name],
        email: attrs[:email],
        department: attrs[:department],
        job_title: attrs[:job_title],
        salary_cents: attrs[:salary_cents],
        start_date: attrs[:start_date] || Date.utc_today(),
        status: :active,
        leave_balance_days: @annual_leave_days
      })

    case Repo.insert(changeset) do
      {:ok, employee} ->
        Logger.info("Employee #{employee.id} (#{employee.email}) onboarded")

        Mailer.deliver(%{
          to: employee.email,
          subject: "Welcome to the team!",
          text_body: "Welcome, #{employee.first_name}! Your start date is #{employee.start_date}."
        })

        {:ok, employee}

      {:error, cs} ->
        {:error, cs}
    end
  end

  # --- Profile update ---

  def update_employee(%Employee{} = employee, attrs) do
    allowed = Map.take(attrs, [:job_title, :department, :manager_id, :work_location])

    employee
    |> Employee.changeset(allowed)
    |> Repo.update()
  end

  # --- Termination ---

  def terminate_employee(%Employee{} = employee, %{reason: reason, last_day: last_day}) do
    with {:ok, terminated} <-
           employee
           |> Employee.changeset(%{
                status: :terminated,
                termination_reason: reason,
                last_day: last_day
              })
           |> Repo.update() do
      Logger.info("Employee #{employee.id} terminated effective #{last_day}")

      Mailer.deliver(%{
        to: employee.email,
        subject: "Your employment record has been updated",
        text_body: "This confirms your last working day is #{last_day}. HR will follow up shortly."
      })

      {:ok, terminated}
    end
  end

  # --- Leave request ---

  def record_leave_request(%Employee{} = employee, %{type: type, from: from_date, to: to_date}) do
    days_requested = Date.diff(to_date, from_date) + 1

    cond do
      days_requested <= 0 ->
        {:error, :invalid_date_range}

      type == :annual and employee.leave_balance_days < days_requested ->
        {:error, :insufficient_leave_balance}

      true ->
        attrs = %{
          employee_id: employee.id,
          type: type,
          from_date: from_date,
          to_date: to_date,
          days: days_requested,
          status: :pending,
          submitted_at: DateTime.utc_now()
        }

        Repo.insert(LeaveRequest.changeset(%LeaveRequest{}, attrs))
    end
  end

  # --- Leave approval ---

  def approve_leave(%LeaveRequest{} = request) do
    employee = Repo.get!(Employee, request.employee_id)

    Repo.transaction(fn ->
      Repo.update!(LeaveRequest.changeset(request, %{status: :approved, approved_at: DateTime.utc_now()}))

      if request.type == :annual do
        employee
        |> Employee.changeset(%{leave_balance_days: employee.leave_balance_days - request.days})
        |> Repo.update!()
      end
    end)
  end

  def reject_leave(%LeaveRequest{} = request, reason) do
    request
    |> LeaveRequest.changeset(%{status: :rejected, rejection_reason: reason})
    |> Repo.update()
  end

  # --- Payroll calculation ---

  def calculate_payroll(%Employee{} = employee, period_date) do
    daily_rate = employee.salary_cents / @working_days_per_month

    approved_leaves =
      from(lr in LeaveRequest,
        where:
          lr.employee_id == ^employee.id and
            lr.status == :approved and
            fragment("date_trunc('month', ?)", lr.from_date) ==
              fragment("date_trunc('month', ?)", ^period_date)
      )
      |> Repo.all()

    leave_days = Enum.sum(Enum.map(approved_leaves, & &1.days))
    deduction  = round(daily_rate * leave_days)
    gross_pay  = employee.salary_cents
    net_pay    = gross_pay - deduction

    %{
      employee_id: employee.id,
      period: period_date,
      gross_cents: gross_pay,
      leave_deduction_cents: deduction,
      net_cents: net_pay
    }
  end

  # --- Payslip generation ---

  def generate_payslip(%Employee{} = employee, period_date) do
    payroll = calculate_payroll(employee, period_date)

    entry_attrs = %{
      employee_id: employee.id,
      period: period_date,
      gross_cents: payroll.gross_cents,
      deductions_cents: payroll.leave_deduction_cents,
      net_cents: payroll.net_cents,
      issued_at: DateTime.utc_now()
    }

    case Repo.insert(PayrollEntry.changeset(%PayrollEntry{}, entry_attrs)) do
      {:ok, entry} ->
        Logger.info("Payslip generated for employee #{employee.id} period #{period_date}")
        {:ok, entry}

      {:error, cs} ->
        {:error, cs}
    end
  end

  # --- Performance reviews ---

  def track_performance_review(%Employee{} = employee, %{reviewer_id: rid, score: score, notes: notes}) do
    attrs = %{
      employee_id: employee.id,
      reviewer_id: rid,
      score: score,
      notes: notes,
      review_date: Date.utc_today()
    }

    case Repo.insert(PerformanceReview.changeset(%PerformanceReview{}, attrs)) do
      {:ok, review} -> {:ok, review}
      {:error, cs} -> {:error, cs}
    end
  end

  # --- Headcount reporting ---

  def export_headcount_report(department \\ nil) do
    query =
      from(e in Employee,
        where: e.status == :active,
        order_by: [asc: e.department, asc: e.last_name]
      )

    query =
      if department, do: where(query, [e], e.department == ^department), else: query

    employees = Repo.all(query)

    header = "id,first_name,last_name,email,department,job_title,start_date\n"

    rows =
      Enum.map(employees, fn e ->
        "#{e.id},#{e.first_name},#{e.last_name},#{e.email},#{e.department},#{e.job_title},#{e.start_date}\n"
      end)

    [header | rows] |> Enum.join()
  end
end
# VALIDATION: SMELL END
```
