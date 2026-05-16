# Example 38: HR Leave Management System - Annotated

## Metadata
- **Smell Name**: Working with invalid data
- **Expected Location**: `HR.LeaveManager.submit_leave_request/4` function
- **Affected Functions**: `submit_leave_request/4`
- **Explanation**: The function does not validate that `start_date` and `end_date` are actual `Date` structs before passing them to `Date.diff/2`. If a caller supplies raw strings or integers, the error will surface inside the `Date` module rather than at the public API boundary.

## Code

```elixir
defmodule HR.LeaveManager do
  @moduledoc """
  Manages employee leave requests, accrual balances, approval workflows,
  and public holiday calendars for the HR platform.
  """

  alias HR.{Employee, LeaveRequest, LeaveBalance, ApprovalWorkflow, Calendar, Notification}

  @leave_types [:annual, :sick, :parental, :bereavement, :unpaid]
  @max_consecutive_days 30

  def fetch_leave_balance(employee_id) do
    with {:ok, employee} <- Employee.get(employee_id),
         {:ok, balance} <- LeaveBalance.get_for_employee(employee_id) do

      {:ok, %{
        employee_id: employee_id,
        employee_name: employee.full_name,
        annual_days_remaining: balance.annual,
        sick_days_remaining: balance.sick,
        parental_days_remaining: balance.parental,
        as_of: Date.utc_today()
      }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # VALIDATION: SMELL START - Working with invalid data
  # VALIDATION: This is a smell because `start_date` and `end_date` are passed
  # VALIDATION: directly into Date.diff/2 without any type validation. If a caller
  # VALIDATION: passes ISO strings ("2025-06-01") instead of Date structs, the error
  # VALIDATION: will originate inside the Date module with a confusing protocol
  # VALIDATION: dispatch error, rather than a clear boundary validation message.
  def submit_leave_request(employee_id, leave_type, start_date, end_date) do
    with {:ok, employee} <- Employee.get(employee_id),
         {:ok, balance} <- LeaveBalance.get_for_employee(employee_id),
         :ok <- validate_leave_type(leave_type),
         :ok <- validate_date_order(start_date, end_date) do

      # No type validation on start_date / end_date before Date.diff/2
      working_days = count_working_days(start_date, end_date)
      calendar_days = Date.diff(end_date, start_date) + 1

      with :ok <- validate_balance_sufficient(balance, leave_type, working_days),
           :ok <- validate_no_overlap(employee_id, start_date, end_date),
           :ok <- validate_consecutive_limit(calendar_days) do

        request = %LeaveRequest{
          id: generate_request_id(),
          employee_id: employee_id,
          leave_type: leave_type,
          start_date: start_date,
          end_date: end_date,
          working_days: working_days,
          calendar_days: calendar_days,
          status: :pending,
          submitted_at: DateTime.utc_now()
        }

        {:ok, _} = LeaveRequest.insert(request)
        {:ok, workflow} = ApprovalWorkflow.initiate(request, employee.manager_id)
        {:ok, _} = Notification.send(employee.manager_id, :new_leave_request, request)

        {:ok, request}
      else
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end
  # VALIDATION: SMELL END

  def approve_leave_request(request_id, approver_id, notes \\ nil) do
    with {:ok, request} <- LeaveRequest.get(request_id),
         {:ok, approver} <- Employee.get(approver_id),
         :ok <- validate_approver_authority(request, approver),
         {:ok, balance} <- LeaveBalance.get_for_employee(request.employee_id) do

      {:ok, _} = LeaveRequest.update(request_id, %{status: :approved, approved_at: DateTime.utc_now(), approver_notes: notes})
      {:ok, _} = LeaveBalance.deduct(request.employee_id, request.leave_type, request.working_days)
      {:ok, _} = Notification.send(request.employee_id, :leave_approved, request)

      {:ok, :approved}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def reject_leave_request(request_id, approver_id, reason) do
    with {:ok, request} <- LeaveRequest.get(request_id),
         {:ok, approver} <- Employee.get(approver_id),
         :ok <- validate_approver_authority(request, approver) do

      {:ok, _} = LeaveRequest.update(request_id, %{
        status: :rejected,
        rejected_at: DateTime.utc_now(),
        rejection_reason: reason
      })
      {:ok, _} = Notification.send(request.employee_id, :leave_rejected, request)

      {:ok, :rejected}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def cancel_leave_request(request_id, employee_id) do
    with {:ok, request} <- LeaveRequest.get(request_id),
         :ok <- validate_cancellable(request, employee_id) do

      refund_required = request.status == :approved

      {:ok, _} = LeaveRequest.update(request_id, %{status: :cancelled, cancelled_at: DateTime.utc_now()})

      if refund_required do
        {:ok, _} = LeaveBalance.refund(employee_id, request.leave_type, request.working_days)
      end

      {:ok, _} = Notification.send(request.employee_id, :leave_cancelled, request)

      {:ok, :cancelled}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def list_team_leave(manager_id, month, year) do
    with {:ok, manager} <- Employee.get(manager_id),
         {:ok, team} <- Employee.list_direct_reports(manager_id),
         {:ok, requests} <- LeaveRequest.list_for_team_in_month(Enum.map(team, & &1.id), month, year) do

      grouped =
        Enum.group_by(requests, & &1.employee_id)
        |> Enum.map(fn {emp_id, reqs} ->
          emp = Enum.find(team, &(&1.id == emp_id))
          %{employee: emp.full_name, requests: Enum.map(reqs, &summarize_request/1)}
        end)

      {:ok, %{manager: manager.full_name, month: month, year: year, team_leave: grouped}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp count_working_days(start_date, end_date) do
    Date.range(start_date, end_date)
    |> Enum.count(fn date ->
      day = Date.day_of_week(date)
      day not in [6, 7] and not Calendar.public_holiday?(date)
    end)
  end

  defp validate_leave_type(type) when type in @leave_types, do: :ok
  defp validate_leave_type(_), do: {:error, :invalid_leave_type}

  defp validate_date_order(start_date, end_date) do
    if Date.compare(start_date, end_date) in [:lt, :eq] do
      :ok
    else
      {:error, :end_date_before_start_date}
    end
  end

  defp validate_balance_sufficient(balance, leave_type, days) do
    available = Map.get(balance, leave_type, 0)
    if available >= days, do: :ok, else: {:error, :insufficient_balance}
  end

  defp validate_no_overlap(employee_id, start_date, end_date) do
    case LeaveRequest.find_overlapping(employee_id, start_date, end_date) do
      {:ok, []} -> :ok
      {:ok, _} -> {:error, :overlapping_request_exists}
      error -> error
    end
  end

  defp validate_consecutive_limit(days) when days <= @max_consecutive_days, do: :ok
  defp validate_consecutive_limit(_), do: {:error, :exceeds_consecutive_limit}

  defp validate_approver_authority(request, approver) do
    case Employee.get(request.employee_id) do
      {:ok, emp} when emp.manager_id == approver.id -> :ok
      _ -> {:error, :unauthorized_approver}
    end
  end

  defp validate_cancellable(%{status: :pending}, _employee_id), do: :ok
  defp validate_cancellable(%{status: :approved, employee_id: eid}, eid), do: :ok
  defp validate_cancellable(_, _), do: {:error, :cannot_cancel}

  defp summarize_request(r) do
    %{id: r.id, type: r.leave_type, from: r.start_date, to: r.end_date, status: r.status}
  end

  defp generate_request_id do
    "lr_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end
end
```
