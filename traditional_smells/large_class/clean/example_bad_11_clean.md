```elixir
defmodule MyApp.EmployeeManager do
  @moduledoc """
  Handles all employee operations: onboarding, offboarding, leave,
  performance reviews, payroll, payslips, and HR reporting.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.HR.{Employee, LeaveRequest, PerformanceReview, Payroll, Payslip}
  alias MyApp.Accounts.User

  @leave_types     [:annual, :sick, :parental, :unpaid]
  @annual_leave_days 20


  def onboard(attrs) do
    Repo.transaction(fn ->
      user = Repo.insert!(User.changeset(%User{}, %{
        email:     attrs[:email],
        password_hash: MyApp.Crypto.hash_password(MyApp.Crypto.random_password()),
        status:    :active
      }))

      employee = Repo.insert!(%Employee{
        user_id:       user.id,
        first_name:    attrs[:first_name],
        last_name:     attrs[:last_name],
        department:    attrs[:department],
        job_title:     attrs[:job_title],
        salary_cents:  attrs[:salary_cents],
        start_date:    attrs[:start_date] || Date.utc_today(),
        status:        :active,
        annual_leave_balance: @annual_leave_days
      })

      MyApp.Mailer.deliver(%{
        to:      user.email,
        subject: "Welcome to the team!",
        body:    "Your account is ready. First day: #{employee.start_date}."
      })

      Logger.info("Employee #{employee.id} onboarded: #{employee.first_name} #{employee.last_name}")
      {user, employee}
    end)
  end

  def offboard(employee_id, reason) do
    employee = Repo.get!(Employee, employee_id)

    Repo.update!(Employee.changeset(employee, %{
      status:         :terminated,
      end_date:       Date.utc_today(),
      offboard_reason: reason
    }))

    user = Repo.get!(User, employee.user_id)
    Repo.update!(User.changeset(user, %{status: :inactive}))

    MyApp.Mailer.deliver(%{
      to:      user.email,
      subject: "Your employment has ended",
      body:    "Your access will be revoked. Reason: #{reason}."
    })

    Logger.info("Employee #{employee_id} offboarded. Reason: #{reason}")
    :ok
  end

  def update_employment_details(employee_id, changes) do
    employee = Repo.get!(Employee, employee_id)
    allowed  = Map.take(changes, [:department, :job_title, :salary_cents, :manager_id])

    case Repo.update(Employee.changeset(employee, allowed)) do
      {:ok, updated} -> {:ok, updated}
      {:error, _} = err -> err
    end
  end


  def record_leave_request(employee_id, attrs) do
    leave_type = attrs[:type]

    unless leave_type in @leave_types do
      raise ArgumentError, "Invalid leave type: #{leave_type}"
    end

    employee = Repo.get!(Employee, employee_id)

    if leave_type == :annual and employee.annual_leave_balance < attrs[:days] do
      {:error, :insufficient_leave_balance}
    else
      Repo.insert(%LeaveRequest{
        employee_id:  employee_id,
        leave_type:   leave_type,
        start_date:   attrs[:start_date],
        end_date:     attrs[:end_date],
        days:         attrs[:days],
        reason:       attrs[:reason],
        status:       :pending
      })
    end
  end

  def approve_leave(%LeaveRequest{status: :pending} = request) do
    employee = Repo.get!(Employee, request.employee_id)

    updates = %{status: :approved, approved_at: DateTime.utc_now()}

    updated_employee =
      if request.leave_type == :annual do
        Repo.update!(Employee.changeset(employee, %{
          annual_leave_balance: employee.annual_leave_balance - request.days
        }))
      else
        employee
      end

    Repo.update!(LeaveRequest.changeset(request, updates))

    user = Repo.get!(User, updated_employee.user_id)
    MyApp.Mailer.deliver(%{
      to:      user.email,
      subject: "Leave approved",
      body:    "Your #{request.leave_type} leave #{request.start_date}–#{request.end_date} is approved."
    })

    :ok
  end

  def approve_leave(_), do: {:error, :not_pending}

  def reject_leave(%LeaveRequest{status: :pending} = request, reason) do
    Repo.update!(LeaveRequest.changeset(request, %{status: :rejected, rejection_reason: reason}))

    employee = Repo.get!(Employee, request.employee_id)
    user     = Repo.get!(User, employee.user_id)

    MyApp.Mailer.deliver(%{
      to:      user.email,
      subject: "Leave request declined",
      body:    "Your leave request was declined. Reason: #{reason}."
    })

    :ok
  end

  def reject_leave(_, _), do: {:error, :not_pending}


  def record_performance_review(employee_id, attrs) do
    Repo.insert(%PerformanceReview{
      employee_id:   employee_id,
      reviewer_id:   attrs[:reviewer_id],
      period:        attrs[:period],
      rating:        attrs[:rating],
      comments:      attrs[:comments],
      goals_met:     attrs[:goals_met],
      reviewed_at:   DateTime.utc_now()
    })
  end

  def latest_review(employee_id) do
    from(pr in PerformanceReview,
      where: pr.employee_id == ^employee_id,
      order_by: [desc: pr.reviewed_at],
      limit: 1
    )
    |> Repo.one()
  end


  def compute_payroll(employee_id, period) do
    employee = Repo.get!(Employee, employee_id)

    gross          = employee.salary_cents
    income_tax     = round(gross * 0.20)
    social_contrib = round(gross * 0.08)
    net            = gross - income_tax - social_contrib

    Repo.insert!(%Payroll{
      employee_id:    employee_id,
      period:         period,
      gross_cents:    gross,
      tax_cents:      income_tax,
      contrib_cents:  social_contrib,
      net_cents:      net,
      computed_at:    DateTime.utc_now()
    })
  end

  def generate_payslip(employee_id, period) do
    payroll  = Repo.get_by!(Payroll, employee_id: employee_id, period: period)
    employee = Repo.get!(Employee, employee_id)
    user     = Repo.get!(User, employee.user_id)

    content = """
    PAYSLIP - #{period}
    Employee: #{employee.first_name} #{employee.last_name}
    Gross: #{format_money(payroll.gross_cents)}
    Tax: #{format_money(payroll.tax_cents)}
    Social: #{format_money(payroll.contrib_cents)}
    Net: #{format_money(payroll.net_cents)}
    """

    Repo.insert!(%Payslip{
      payroll_id:   payroll.id,
      employee_id:  employee_id,
      content:      content,
      generated_at: DateTime.utc_now()
    })

    MyApp.Mailer.deliver(%{
      to:          user.email,
      subject:     "Payslip for #{period}",
      body:        "Please find your payslip attached.",
      attachments: [%{name: "payslip_#{period}.txt", data: content}]
    })

    {:ok, content}
  end


  def list_employees(filters \\ %{}) do
    base = from e in Employee, where: e.status == :active

    base =
      if dept = filters[:department],
        do: from(e in base, where: e.department == ^dept),
        else: base

    Repo.all(base)
  end

  def headcount_report do
    from(e in Employee,
      where: e.status == :active,
      group_by: e.department,
      select: %{department: e.department, headcount: count(e.id)}
    )
    |> Repo.all()
  end


  defp format_money(cents) do
    "$#{Float.round(cents / 100, 2)}"
  end
end
```
