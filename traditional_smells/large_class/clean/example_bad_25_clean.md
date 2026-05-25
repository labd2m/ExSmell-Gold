```elixir
defmodule HRManager do
  @moduledoc """
  Manages all human resources operations across the employee lifecycle.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.HR.{Employee, LeaveRequest, PayrollRun, PerformanceReview, OnboardingTask}
  alias MyApp.Auth.User
  alias MyApp.Mailer

  @base_salary_currency "USD"
  @standard_leave_days 20
  @probation_months 3
  @performance_review_cycle_months 6


  def onboard_employee(attrs) do
    with {:ok, user} <- create_user_account(attrs),
         {:ok, employee} <-
           Repo.insert(%Employee{
             user_id: user.id,
             department: attrs.department,
             job_title: attrs.job_title,
             base_salary: attrs.base_salary,
             start_date: attrs.start_date,
             status: :active,
             probation_end: Date.add(attrs.start_date, @probation_months * 30)
           }),
         {:ok, _} <- provision_onboarding_tasks(employee) do
      send_welcome_email(user, employee)
      Logger.info("Employee #{employee.id} onboarded successfully")
      {:ok, employee}
    end
  end

  defp create_user_account(%{email: email, name: name}) do
    Repo.insert(%User{
      email: email,
      name: name,
      role: :employee,
      temporary_password: :crypto.strong_rand_bytes(8) |> Base.encode16()
    })
  end

  defp provision_onboarding_tasks(%Employee{id: emp_id}) do
    tasks = [
      "Complete I-9 verification",
      "Sign employment contract",
      "Set up direct deposit",
      "Complete compliance training",
      "Meet with IT for system access"
    ]

    results =
      Enum.map(tasks, fn task ->
        Repo.insert(%OnboardingTask{employee_id: emp_id, description: task, status: :pending})
      end)

    if Enum.all?(results, &match?({:ok, _}, &1)),
      do: {:ok, results},
      else: {:error, :task_provisioning_failed}
  end


  def run_payroll(period_start, period_end) do
    employees = Repo.all(from e in Employee, where: e.status == :active)

    entries =
      Enum.map(employees, fn emp ->
        gross = calculate_gross(emp, period_start, period_end)
        deductions = calculate_deductions(gross, emp)
        net = Decimal.sub(gross, deductions)

        %{employee_id: emp.id, gross: gross, deductions: deductions, net: net}
      end)

    {:ok, run} =
      Repo.insert(%PayrollRun{
        period_start: period_start,
        period_end: period_end,
        entries: entries,
        total_gross: Enum.reduce(entries, Decimal.new(0), &Decimal.add(&2, &1.gross)),
        currency: @base_salary_currency,
        run_at: DateTime.utc_now()
      })

    Logger.info("Payroll run #{run.id} completed for #{length(entries)} employees")
    {:ok, run}
  end

  defp calculate_gross(%Employee{base_salary: monthly_salary}, from_date, to_date) do
    days_in_period = Date.diff(to_date, from_date)
    days_in_month = Date.days_in_month(from_date)
    Decimal.mult(monthly_salary, Decimal.div(days_in_period, days_in_month))
  end

  defp calculate_deductions(gross, %Employee{department: dept}) do
    tax_rate = if dept == "Executive", do: Decimal.from_float(0.35), else: Decimal.from_float(0.25)
    social_security = Decimal.mult(gross, Decimal.from_float(0.06))
    income_tax = Decimal.mult(gross, tax_rate)
    Decimal.add(social_security, income_tax)
  end


  def request_leave(employee_id, %{type: type, from: from_date, to: to_date, reason: reason}) do
    employee = Repo.get!(Employee, employee_id)
    days_requested = Date.diff(to_date, from_date) + 1

    with :ok <- validate_leave_balance(employee, type, days_requested),
         {:ok, request} <-
           Repo.insert(%LeaveRequest{
             employee_id: employee_id,
             type: type,
             from_date: from_date,
             to_date: to_date,
             days: days_requested,
             reason: reason,
             status: :pending,
             requested_at: DateTime.utc_now()
           }) do
      notify_manager(employee, request)
      {:ok, request}
    end
  end

  defp validate_leave_balance(%Employee{leave_balance: balance}, :annual, days)
       when balance < days,
       do: {:error, :insufficient_leave_balance}

  defp validate_leave_balance(_, _, _), do: :ok

  def approve_leave(request_id, approver_id) do
    request = Repo.get!(LeaveRequest, request_id)

    request
    |> LeaveRequest.changeset(%{
      status: :approved,
      approved_by: approver_id,
      approved_at: DateTime.utc_now()
    })
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        deduct_leave_balance(request.employee_id, request.days)
        {:ok, updated}

      err ->
        err
    end
  end

  defp deduct_leave_balance(employee_id, days) do
    Repo.get!(Employee, employee_id)
    |> Employee.changeset(%{leave_balance: Repo.get!(Employee, employee_id).leave_balance - days})
    |> Repo.update()
  end

  defp notify_manager(employee, request) do
    manager = Repo.get!(User, employee.manager_id)

    Mailer.send(%{
      to: manager.email,
      subject: "Leave request from #{employee.name}",
      body: "#{employee.name} has requested #{request.days} day(s) of leave."
    })
  end


  def initiate_review_cycle do
    cutoff = Date.add(Date.utc_today(), -@performance_review_cycle_months * 30)

    employees =
      Repo.all(
        from e in Employee,
          where:
            e.status == :active and
              (is_nil(e.last_review_date) or e.last_review_date <= ^cutoff)
      )

    Enum.each(employees, fn emp ->
      {:ok, _} =
        Repo.insert(%PerformanceReview{
          employee_id: emp.id,
          review_period_start: cutoff,
          review_period_end: Date.utc_today(),
          status: :pending,
          initiated_at: DateTime.utc_now()
        })
    end)

    Logger.info("Performance review cycle initiated for #{length(employees)} employees")
  end

  def submit_review(review_id, %{rating: rating, comments: comments, goals: goals}) do
    Repo.get!(PerformanceReview, review_id)
    |> PerformanceReview.changeset(%{
      rating: rating,
      comments: comments,
      goals: goals,
      status: :completed,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update()
  end


  def offboard_employee(employee_id, %{reason: reason, last_day: last_day}) do
    employee = Repo.get!(Employee, employee_id)

    with {:ok, updated} <-
           employee
           |> Employee.changeset(%{
             status: :terminated,
             termination_reason: reason,
             last_day: last_day
           })
           |> Repo.update() do
      revoke_system_access(employee)
      archive_employee_data(employee)
      send_offboarding_email(employee)
      Logger.info("Employee #{employee_id} offboarded. Last day: #{last_day}")
      {:ok, updated}
    end
  end

  defp revoke_system_access(%Employee{user_id: uid}) do
    Repo.get!(User, uid)
    |> User.changeset(%{active: false, deactivated_at: DateTime.utc_now()})
    |> Repo.update()
  end

  defp archive_employee_data(%Employee{id: emp_id}) do
    Logger.info("Archiving data for employee #{emp_id}")
  end

  defp send_offboarding_email(%Employee{name: name, email: email, last_day: last_day}) do
    Mailer.send(%{
      to: email,
      subject: "Your offboarding details",
      body: "Dear #{name}, your last day is confirmed as #{last_day}. HR will be in touch."
    })
  end

  defp send_welcome_email(user, employee) do
    Mailer.send(%{
      to: user.email,
      subject: "Welcome to the team, #{employee.name}!",
      body: "We're excited to have you. Your first day is #{employee.start_date}."
    })
  end
end
```
