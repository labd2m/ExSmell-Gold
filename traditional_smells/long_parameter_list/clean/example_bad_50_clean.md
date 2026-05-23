```elixir
defmodule HR.Onboarding do
  @moduledoc """
  Coordinates new employee onboarding: record creation, payroll setup,
  and IT access provisioning.
  """

  require Logger

  @valid_employment_types ~w(full_time part_time contractor intern)
  @valid_departments ~w(engineering product design sales marketing operations finance hr legal)

  def onboard_employee(
        full_name,
        personal_email,
        start_date,
        department,
        job_title,
        employment_type,
        salary_cents,
        manager_id,
        laptop_required,
        access_level,
        send_welcome_email,
        enroll_in_benefits,
        remote_worker
      ) do
    with :ok <- validate_name(full_name),
         :ok <- validate_email(personal_email),
         :ok <- validate_start_date(start_date),
         :ok <- validate_department(department),
         :ok <- validate_employment_type(employment_type),
         :ok <- validate_salary(salary_cents) do
      employee = %{
        id: generate_employee_id(),
        full_name: String.trim(full_name),
        personal_email: String.downcase(personal_email),
        work_email: generate_work_email(full_name),
        start_date: start_date,
        department: department,
        job_title: job_title,
        employment_type: employment_type,
        compensation: %{salary_cents: salary_cents, currency: "BRL"},
        manager_id: manager_id,
        remote_worker: remote_worker,
        provisioning: %{
          laptop_required: laptop_required,
          access_level: access_level
        },
        benefits_enrolled: false,
        status: :pending,
        created_at: DateTime.utc_now()
      }

      with {:ok, saved} <- persist_employee(employee),
           :ok <- provision_it_access(saved, access_level, laptop_required),
           {:ok, saved} <- maybe_enroll_benefits(saved, enroll_in_benefits),
           :ok <- notify_team(saved, send_welcome_email) do
        Logger.info("Employee #{saved.id} onboarded: #{full_name} in #{department}")
        {:ok, saved}
      else
        {:error, :email_conflict} ->
          {:error, :work_email_taken}

        {:error, reason} ->
          Logger.error("Onboarding failed for #{full_name}: #{inspect(reason)}")
          {:error, :onboarding_failed}
      end
    end
  end

  defp validate_name(n) when byte_size(n) > 1, do: :ok
  defp validate_name(_), do: {:error, "full_name is required"}

  defp validate_email(email) do
    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email), do: :ok, else: {:error, "invalid personal_email"}
  end

  defp validate_start_date(%Date{} = d) do
    if Date.compare(d, Date.utc_today()) != :lt, do: :ok, else: {:error, "start_date must be today or in the future"}
  end
  defp validate_start_date(_), do: {:error, "start_date must be a Date"}

  defp validate_department(d) when d in @valid_departments, do: :ok
  defp validate_department(d), do: {:error, "unknown department: #{d}"}

  defp validate_employment_type(t) when t in @valid_employment_types, do: :ok
  defp validate_employment_type(t), do: {:error, "invalid employment_type: #{t}"}

  defp validate_salary(cents) when is_integer(cents) and cents > 0, do: :ok
  defp validate_salary(_), do: {:error, "salary_cents must be a positive integer"}

  defp persist_employee(employee), do: {:ok, employee}

  defp provision_it_access(employee, level, laptop) do
    Logger.debug("Provisioning #{level} access for #{employee.id}, laptop=#{laptop}")
    :ok
  end

  defp maybe_enroll_benefits(employee, false), do: {:ok, employee}
  defp maybe_enroll_benefits(employee, true) do
    Logger.debug("Enrolling #{employee.id} in benefits plan")
    {:ok, Map.put(employee, :benefits_enrolled, true)}
  end

  defp notify_team(employee, false), do: :ok
  defp notify_team(employee, true) do
    Logger.debug("Sending welcome email to #{employee.personal_email}")
    :ok
  end

  defp generate_work_email(full_name) do
    slug =
      full_name
      |> String.downcase()
      |> String.replace(~r/\s+/, ".")
      |> String.replace(~r/[^a-z.]/, "")

    "#{slug}@company.com"
  end

  defp generate_employee_id do
    "EMP-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
