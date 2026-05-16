# Example 38

```elixir
defmodule UserManagement.EmployeeOnboarding do
  @moduledoc """
  Manages employee onboarding by registering new hires in the HRCore API,
  assigning roles, provisioning access, and notifying relevant teams.
  """

  require Logger

  alias UserManagement.Repo
  alias UserManagement.Schema.{Employee, Department, OnboardingRecord}
  alias UserManagement.HRCore.Client
  alias UserManagement.AccessProvisioner
  alias UserManagement.Notifications

  @employment_types [:full_time, :part_time, :contractor, :intern]
  @required_fields ~w(first_name last_name email role department_id start_date)a

  def onboard(department_id, employee_params, employment_type \\ :full_time)
      when employment_type in @employment_types do
    with :ok <- validate_required(employee_params),
         {:ok, dept} <- fetch_department(department_id),
         :ok <- check_headcount(dept),
         {:ok, payload} <- build_payload(employee_params, dept, employment_type) do
      enroll_employee(dept, Client.post("/employees", payload))
    end
  end

  defp fetch_department(id) do
    case Repo.get(Department, id) do
      nil -> {:error, :department_not_found}
      d -> {:ok, d}
    end
  end

  defp validate_required(params) do
    missing = Enum.filter(@required_fields, &(not Map.has_key?(params, &1)))

    case missing do
      [] -> :ok
      fields -> {:error, {:missing_fields, fields}}
    end
  end

  defp check_headcount(%Department{headcount: hc, headcount_limit: limit})
       when hc >= limit,
       do: {:error, :headcount_limit_reached}

  defp check_headcount(_), do: :ok

  defp build_payload(params, dept, type) do
    {:ok, Map.merge(params, %{department_code: dept.code, employment_type: type})}
  end

  defp enroll_employee(dept, hr_response) do
    case hr_response do
      {:ok, %{status: 201, body: %{"employee_id" => eid, "status" => "active", "access_profile" => profile}}} ->
        Logger.info("Employee #{eid} enrolled and active in dept #{dept.id}")

        {:ok, record} =
          Repo.insert(%OnboardingRecord{
            department_id: dept.id,
            employee_id: eid,
            status: :active
          })

        AccessProvisioner.provision(eid, profile)
        Notifications.send_welcome(eid)
        {:ok, record}

      {:ok, %{status: 202, body: %{"employee_id" => eid, "status" => "pending_background_check", "eta_days" => eta}}} ->
        Logger.info("Employee #{eid} pending background check, eta #{eta} days")

        {:ok, record} =
          Repo.insert(%OnboardingRecord{
            department_id: dept.id,
            employee_id: eid,
            status: :pending_background_check
          })

        Notifications.send_pending_notice(eid, eta)
        {:ok, record}

      {:ok, %{status: 409, body: %{"error" => "employee_already_exists", "existing_id" => existing}}} ->
        Logger.warning("Duplicate employee detected in dept #{dept.id}, existing id #{existing}")
        {:error, {:already_exists, existing}}

      {:ok, %{status: 422, body: %{"error" => "role_not_permitted_in_department"}}} ->
        Logger.warning("Role not allowed in dept #{dept.id}")
        {:error, :role_not_permitted}

      {:ok, %{status: 422, body: %{"error" => "email_domain_not_allowed"}}} ->
        Logger.warning("Email domain not allowed for dept #{dept.id}")
        {:error, :email_domain_not_allowed}

      {:ok, %{status: 402, body: %{"error" => "license_seat_unavailable", "plan" => plan}}} ->
        Logger.error("No license seat available for plan #{plan} in dept #{dept.id}")
        Notifications.send_license_alert(dept)
        {:error, {:no_license_seat, plan}}

      {:ok, %{status: 403, body: %{"error" => "department_locked"}}} ->
        Logger.warning("Department #{dept.id} is locked, enrolment blocked")
        {:error, :department_locked}

      {:ok, %{status: 404, body: %{"error" => "role_not_found"}}} ->
        Logger.warning("Specified role not found in HRCore for dept #{dept.id}")
        {:error, :role_not_found}

      {:ok, %{status: 422, body: %{"error" => "start_date_in_past"}}} ->
        Logger.warning("Start date in the past for dept #{dept.id} enrolment")
        {:error, :start_date_in_past}

      {:ok, %{status: 429, body: _}} ->
        Logger.warning("Rate limited by HRCore for dept #{dept.id}")
        {:error, :rate_limited}

      {:ok, %{status: 503, body: _}} ->
        Logger.error("HRCore unavailable during enrolment for dept #{dept.id}")
        {:error, :hr_platform_unavailable}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Unexpected HRCore response #{status} for dept #{dept.id}: #{inspect(body)}")
        {:error, {:unexpected_response, status}}

      {:error, %{reason: :timeout}} ->
        Logger.error("HRCore timeout during enrolment for dept #{dept.id}")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("HRCore error during enrolment for dept #{dept.id}: #{inspect(reason)}")
        {:error, {:hr_error, reason}}
    end
  end

  def offboard(employee_id, reason \\ "resignation") do
    case Client.delete("/employees/#{employee_id}", %{reason: reason}) do
      {:ok, %{status: 200}} ->
        Employee
        |> Repo.get_by(external_id: employee_id)
        |> Employee.changeset(%{status: :offboarded})
        |> Repo.update()

      {:ok, %{status: _, body: body}} ->
        {:error, body}

      {:error, _} = err ->
        err
    end
  end
end
```
