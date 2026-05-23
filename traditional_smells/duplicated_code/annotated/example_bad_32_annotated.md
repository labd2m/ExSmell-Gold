# Annotated Example — Duplicated Code

## Metadata

- **Smell name:** Duplicated Code
- **Expected smell location:** `BenefitsEnrollment.enroll_health/2` and `BenefitsEnrollment.enroll_dental/2`
- **Affected functions:** `enroll_health/2`, `enroll_dental/2`
- **Short explanation:** Both enrollment functions independently check that the employee is active, has completed the minimum tenure, and that enrollment is currently within an open window. This eligibility-check block is duplicated across both functions.

---

```elixir
defmodule BenefitsEnrollment do
  @moduledoc """
  Manages employee benefits enrollment for health, dental, and vision plans.
  """

  alias HR.{Employee, EnrollmentRecord, EnrollmentWindow, PlanCatalog, Payroll, Notifier}

  @min_tenure_days 90
  @active_employment_statuses [:active, :on_leave]

  def enroll_health(employee_id, plan_code) do
    with {:ok, employee} <- Employee.fetch(employee_id),
         # VALIDATION: SMELL START - Duplicated Code
         # VALIDATION: This is a smell because the three eligibility checks below
         # (active status, minimum tenure, open enrollment window) are written out
         # identically in `enroll_dental/2`. Any policy change must be applied twice.
         :ok <- check_employment_status(employee),
         :ok <- check_minimum_tenure(employee),
         :ok <- check_enrollment_window(:health),
         # VALIDATION: SMELL END
         {:ok, plan} <- PlanCatalog.fetch(:health, plan_code),
         :ok <- check_no_existing_enrollment(employee_id, :health) do

      monthly_premium = PlanCatalog.employee_contribution(plan, employee.tier)

      record = %EnrollmentRecord{
        id: Ecto.UUID.generate(),
        employee_id: employee_id,
        benefit_type: :health,
        plan_code: plan_code,
        plan_name: plan.name,
        monthly_premium: monthly_premium,
        effective_date: next_effective_date(),
        status: :pending_payroll,
        enrolled_at: DateTime.utc_now()
      }

      HR.Repo.insert(record)
      Payroll.schedule_deduction(employee_id, :health, monthly_premium)
      Notifier.send_enrollment_confirmation(employee, record)
      {:ok, record}
    end
  end

  def enroll_dental(employee_id, plan_code) do
    with {:ok, employee} <- Employee.fetch(employee_id),
         # VALIDATION: SMELL START - Duplicated Code
         # VALIDATION: This is a smell because the eligibility checks here are a
         # copy-paste of those in `enroll_health/2`. If the minimum tenure policy
         # changes, both functions need updating.
         :ok <- check_employment_status(employee),
         :ok <- check_minimum_tenure(employee),
         :ok <- check_enrollment_window(:dental),
         # VALIDATION: SMELL END
         {:ok, plan} <- PlanCatalog.fetch(:dental, plan_code),
         :ok <- check_no_existing_enrollment(employee_id, :dental) do

      monthly_premium = PlanCatalog.employee_contribution(plan, employee.tier)

      record = %EnrollmentRecord{
        id: Ecto.UUID.generate(),
        employee_id: employee_id,
        benefit_type: :dental,
        plan_code: plan_code,
        plan_name: plan.name,
        monthly_premium: monthly_premium,
        effective_date: next_effective_date(),
        status: :pending_payroll,
        enrolled_at: DateTime.utc_now()
      }

      HR.Repo.insert(record)
      Payroll.schedule_deduction(employee_id, :dental, monthly_premium)
      Notifier.send_enrollment_confirmation(employee, record)
      {:ok, record}
    end
  end

  def terminate_enrollment(employee_id, benefit_type) do
    with {:ok, record} <- EnrollmentRecord.fetch_active(employee_id, benefit_type) do
      EnrollmentRecord.update(record, %{
        status: :terminated,
        terminated_at: DateTime.utc_now()
      })

      Payroll.remove_deduction(employee_id, benefit_type)
      :ok
    end
  end

  defp check_employment_status(%Employee{status: status}) do
    if status in @active_employment_statuses do
      :ok
    else
      {:error, :employee_not_active}
    end
  end

  defp check_minimum_tenure(%Employee{hire_date: hire_date}) do
    tenure_days = Date.diff(Date.utc_today(), hire_date)

    if tenure_days >= @min_tenure_days do
      :ok
    else
      {:error, {:tenure_insufficient, @min_tenure_days - tenure_days}}
    end
  end

  defp check_enrollment_window(benefit_type) do
    case EnrollmentWindow.current(benefit_type) do
      {:ok, _window} -> :ok
      _ -> {:error, :outside_enrollment_window}
    end
  end

  defp check_no_existing_enrollment(employee_id, benefit_type) do
    case EnrollmentRecord.fetch_active(employee_id, benefit_type) do
      {:ok, _} -> {:error, :already_enrolled}
      _ -> :ok
    end
  end

  defp next_effective_date do
    today = Date.utc_today()
    %{today | day: 1} |> Date.add(Date.days_in_month(today))
  end
end
```
