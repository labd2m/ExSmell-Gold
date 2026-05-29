# Annotated Example 21 — Long Parameter List

## Metadata

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `HR.Employees.hire_employee/11` |
| **Affected function(s)** | `hire_employee/11` |
| **Explanation** | The function accepts 11 individual parameters across personal data (first_name, last_name, email, national_id), employment terms (department, job_title, salary, employment_type), and on-boarding config (start_date, manager_id, probation_days). These clearly belong to distinct domain structs rather than a long positional argument list. |

---

```elixir
# VALIDATION: SMELL START - Long Parameter List
# VALIDATION: This is a smell because `hire_employee/11` takes eleven
# individual parameters. Personal information (first_name, last_name, email,
# national_id), employment contract terms (department, job_title, salary,
# employment_type), and onboarding config (start_date, manager_id,
# probation_days) each form a natural grouping. Passing all eleven as
# positional scalars makes call sites verbose and error-prone.
defmodule HR.Employees do
  @moduledoc """
  Manages the hiring workflow, including employee record creation,
  system account provisioning, and onboarding task scheduling.
  """

  require Logger

  alias HR.Repo
  alias HR.Schemas.Employee
  alias HR.Schemas.OnboardingTask
  alias HR.Provisioning
  alias HR.Mailer

  @valid_employment_types ~w(full_time part_time contractor intern)
  @default_probation_days 90

  def hire_employee(
        first_name,
        last_name,
        email,
        national_id,
        department,
        job_title,
        salary,
        employment_type,
        start_date,
        manager_id,
        probation_days
      ) do
# VALIDATION: SMELL END
    with :ok <- validate_name(first_name, :first_name),
         :ok <- validate_name(last_name, :last_name),
         :ok <- validate_email(email),
         :ok <- validate_salary(salary),
         :ok <- validate_employment_type(employment_type),
         :ok <- validate_start_date(start_date) do
      effective_probation = probation_days || @default_probation_days

      employee_attrs = %{
        first_name: String.trim(first_name),
        last_name: String.trim(last_name),
        email: String.downcase(String.trim(email)),
        national_id: national_id,
        department: department,
        job_title: job_title,
        salary: salary,
        employment_type: employment_type,
        start_date: start_date,
        manager_id: manager_id,
        probation_ends_on: Date.add(start_date, effective_probation),
        status: :active,
        inserted_at: DateTime.utc_now()
      }

      Repo.transaction(fn ->
        case Repo.insert(Employee.changeset(%Employee{}, employee_attrs)) do
          {:ok, employee} ->
            Provisioning.create_accounts(employee)
            schedule_onboarding(employee)
            Mailer.send_welcome(employee, manager_id)
            Logger.info("Hired #{employee.email} as #{job_title} in #{department}")
            employee

          {:error, changeset} ->
            Logger.error("Hiring failed: #{inspect(changeset.errors)}")
            Repo.rollback(:hiring_failed)
        end
      end)
    end
  end

  defp schedule_onboarding(employee) do
    tasks = [
      "Complete benefits enrollment",
      "Sign employment contract",
      "IT equipment setup",
      "Security badge issuance",
      "Introduction to team"
    ]

    Enum.each(tasks, fn task ->
      Repo.insert!(OnboardingTask.changeset(%OnboardingTask{}, %{
        employee_id: employee.id,
        description: task,
        due_date: Date.add(employee.start_date, 7),
        status: :pending
      }))
    end)
  end

  defp validate_name(name, field) do
    if is_binary(name) and String.length(String.trim(name)) >= 1 do
      :ok
    else
      {:error, {field, :blank}}
    end
  end

  defp validate_email(email) do
    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email || "") do
      :ok
    else
      {:error, :invalid_email}
    end
  end

  defp validate_salary(s) when is_number(s) and s > 0, do: :ok
  defp validate_salary(_), do: {:error, :invalid_salary}

  defp validate_employment_type(t) when t in @valid_employment_types, do: :ok
  defp validate_employment_type(t), do: {:error, {:unknown_employment_type, t}}

  defp validate_start_date(%Date{} = d) do
    if Date.compare(d, Date.utc_today()) != :lt, do: :ok, else: {:error, :start_date_in_past}
  end

  defp validate_start_date(_), do: {:error, :invalid_start_date}
end
```
