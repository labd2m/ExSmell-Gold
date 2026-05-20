# Annotated Example 22

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `HRWorkflow.process/1`
- **Affected function(s):** `process/1`
- **Short explanation:** `process/1` handles employee onboarding, leave requests, and performance review submissions — three unrelated HR domain workflows — under one multi-clause function, with different actors, integrations, and approval chains per clause.

```elixir
defmodule HRWorkflow do
  @moduledoc """
  Orchestrates HR workflows including employee onboarding,
  leave management, and performance review submissions.
  """

  alias HRWorkflow.{
    OnboardingTask,
    LeaveRequest,
    PerformanceReview,
    EmployeeStore,
    DirectorySync,
    AccessProvisioner,
    LeaveCalendar,
    ReviewCycleStore,
    Payroll,
    Notifier,
    DocumentStore
  }

  require Logger

  @doc """
  Process an HR workflow event.

  Accepts a `%OnboardingTask{}`, `%LeaveRequest{}`, or `%PerformanceReview{}`
  and performs the appropriate HR operation.

  ## Examples

      iex> HRWorkflow.process(%OnboardingTask{employee_id: "emp_001", start_date: ~D[2024-06-01]})
      {:ok, :onboarding_initiated}

  """
  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because initiating employee onboarding,
  # submitting a leave request, and recording a performance review are entirely
  # different HR processes with distinct approval flows, integrations (directory
  # services, payroll, access provisioning), and compliance requirements. They
  # share no meaningful abstraction and should be separate named functions.

  def process(%OnboardingTask{
        employee_id: employee_id,
        start_date: start_date,
        department: department,
        manager_id: manager_id,
        role: role
      }) do
    with {:ok, employee} <- EmployeeStore.find(employee_id),
         :ok <- validate_start_date(start_date),
         {:ok, _} <- DirectorySync.create_account(employee),
         {:ok, provisioned} <- AccessProvisioner.provision_role(employee_id, role, department),
         {:ok, _} <-
           EmployeeStore.update(employee_id, %{
             status: :active,
             start_date: start_date,
             department: department,
             manager_id: manager_id,
             access_groups: provisioned.groups
           }),
         :ok <- Payroll.enroll(employee_id, start_date, role),
         :ok <- Notifier.send_welcome_pack(employee.email, start_date, provisioned),
         :ok <- Notifier.send_manager_notification(manager_id, employee_id) do
      Logger.info("Employee #{employee_id} onboarded to #{department} starting #{start_date}")
      {:ok, :onboarding_initiated}
    end
  end

  # process employee leave request submission
  def process(%LeaveRequest{
        employee_id: employee_id,
        leave_type: leave_type,
        from_date: from_date,
        to_date: to_date,
        reason: reason
      })
      when leave_type in [:annual, :sick, :parental, :unpaid] do
    business_days = count_business_days(from_date, to_date)

    with {:ok, employee} <- EmployeeStore.find(employee_id),
         {:ok, balance} <- LeaveCalendar.get_balance(employee_id, leave_type),
         :ok <- validate_leave_balance(balance, leave_type, business_days),
         :ok <- LeaveCalendar.check_team_coverage(employee.team_id, from_date, to_date),
         {:ok, request} <-
           LeaveCalendar.create_request(%{
             employee_id: employee_id,
             leave_type: leave_type,
             from_date: from_date,
             to_date: to_date,
             business_days: business_days,
             reason: reason,
             status: :pending
           }),
         :ok <- Notifier.send_leave_approval_request(employee.manager_id, request) do
      Logger.info(
        "Leave request #{request.id} submitted for employee #{employee_id}: #{leave_type}"
      )

      {:ok, %{request_id: request.id, status: :pending, days: business_days}}
    end
  end

  # process performance review submission by manager
  def process(%PerformanceReview{
        employee_id: employee_id,
        reviewer_id: reviewer_id,
        cycle_id: cycle_id,
        ratings: ratings,
        comments: comments,
        recommendation: recommendation
      }) do
    with {:ok, cycle} <- ReviewCycleStore.find(cycle_id),
         :ok <- validate_review_open(cycle),
         :ok <- validate_reviewer_authorized(reviewer_id, employee_id),
         {:ok, review} <-
           ReviewCycleStore.submit_review(%{
             employee_id: employee_id,
             reviewer_id: reviewer_id,
             cycle_id: cycle_id,
             ratings: ratings,
             comments: comments,
             recommendation: recommendation,
             submitted_at: DateTime.utc_now()
           }),
         :ok <- maybe_trigger_salary_review(recommendation, employee_id, cycle_id),
         :ok <- Notifier.send_review_submitted(employee_id, reviewer_id, review) do
      Logger.info("Performance review submitted for employee #{employee_id} in cycle #{cycle_id}")
      {:ok, %{review_id: review.id, status: :submitted}}
    end
  end

  # VALIDATION: SMELL END

  defp validate_start_date(date) do
    if Date.compare(date, Date.utc_today()) != :lt do
      :ok
    else
      {:error, :start_date_in_past}
    end
  end

  defp validate_leave_balance(_balance, :sick, _days), do: :ok
  defp validate_leave_balance(balance, _type, days) when balance >= days, do: :ok
  defp validate_leave_balance(_, _, _), do: {:error, :insufficient_leave_balance}

  defp count_business_days(from, to) do
    Date.range(from, to)
    |> Enum.count(fn d -> Date.day_of_week(d) not in [6, 7] end)
  end

  defp validate_review_open(%{status: :open}), do: :ok
  defp validate_review_open(%{status: s}), do: {:error, {:review_cycle_not_open, s}}

  defp validate_reviewer_authorized(reviewer_id, employee_id) do
    case EmployeeStore.find(employee_id) do
      {:ok, %{manager_id: ^reviewer_id}} -> :ok
      _ -> {:error, :not_authorized_reviewer}
    end
  end

  defp maybe_trigger_salary_review(:exceptional, employee_id, cycle_id) do
    Payroll.flag_for_salary_review(employee_id, cycle_id)
  end

  defp maybe_trigger_salary_review(_, _, _), do: :ok
end
```
