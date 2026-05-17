```elixir
# ── file: lib/hr/employee.ex ──────────────────────────────────────────────────

defmodule HR.Employee do
  @moduledoc """
  Manages the onboarding workflow for new hires. Provisions accounts,
  sends welcome communications, and initialises payroll records.
  """

  alias HR.{
    Department,
    Payroll,
    IdentityProvisioner,
    EquipmentService,
    Notifier,
    Repo
  }

  @probation_days 90

  @type t :: %__MODULE__{
          id: String.t(),
          employee_number: String.t(),
          first_name: String.t(),
          last_name: String.t(),
          email: String.t(),
          department_id: String.t(),
          job_title: String.t(),
          start_date: Date.t(),
          probation_end_date: Date.t(),
          employment_type: :full_time | :part_time | :contractor,
          status: :active | :on_leave | :terminated,
          manager_id: String.t() | nil,
          created_at: DateTime.t()
        }

  defstruct [
    :id,
    :employee_number,
    :first_name,
    :last_name,
    :email,
    :department_id,
    :job_title,
    :start_date,
    :probation_end_date,
    :employment_type,
    :manager_id,
    :created_at,
    status: :active
  ]

  @spec onboard(map()) :: {:ok, t()} | {:error, term()}
  def onboard(attrs) do
    with {:ok, dept} <- Department.fetch(attrs[:department_id]),
         :ok <- Department.check_headcount(dept),
         {:ok, emp_number} <- Repo.next_employee_number() do
      start_date = attrs[:start_date] || Date.utc_today()

      employee = %__MODULE__{
        id: generate_id(),
        employee_number: emp_number,
        first_name: attrs[:first_name],
        last_name: attrs[:last_name],
        email: attrs[:email],
        department_id: dept.id,
        job_title: attrs[:job_title],
        start_date: start_date,
        probation_end_date: Date.add(start_date, @probation_days),
        employment_type: attrs[:employment_type] || :full_time,
        manager_id: attrs[:manager_id],
        created_at: DateTime.utc_now()
      }

      Repo.insert(:employees, employee)
      IdentityProvisioner.provision(employee)
      Payroll.initialise(employee)
      EquipmentService.request_setup(employee)
      Notifier.send_welcome(employee)

      {:ok, employee}
    end
  end

  @spec fetch(String.t()) :: {:ok, t()} | {:error, :not_found}
  def fetch(id), do: Repo.fetch(:employees, id)

  @spec list_by_department(String.t()) :: [t()]
  def list_by_department(dept_id) do
    Repo.all(:employees, department_id: dept_id, status: :active)
  end

  @spec update(String.t(), map()) :: {:ok, t()} | {:error, term()}
  def update(id, changes) do
    with {:ok, _emp} <- Repo.fetch(:employees, id) do
      {:ok, Repo.update(:employees, id, changes)}
    end
  end

  defp generate_id, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
end


# ── file: lib/hr/employee_offboarding.ex ─────────────────────────────────────

defmodule HR.Employee do
  @moduledoc """
  Handles employee offboarding: voluntary resignation, involuntary termination,
  and access revocation workflows. Ensures compliance with data-retention rules.
  """

  alias HR.{Payroll, IdentityProvisioner, EquipmentService, Notifier, Repo, AuditLog}

  @access_revocation_delay_hours 0
  @data_retention_years 7

  @spec terminate(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def terminate(employee_id, attrs) do
    reason = Map.fetch!(attrs, :reason)
    termination_date = Map.get(attrs, :termination_date, Date.utc_today())

    with {:ok, employee} <- Repo.fetch(:employees, employee_id),
         :ok <- validate_active(employee) do
      updated =
        employee
        |> Map.put(:status, :terminated)
        |> Map.put(:termination_date, termination_date)
        |> Map.put(:termination_reason, reason)

      Repo.update(:employees, employee_id, Map.from_struct(updated))

      run_offboarding_steps(updated, attrs)

      AuditLog.write(:employee_terminated, %{
        employee_id: employee_id,
        reason: reason,
        termination_date: termination_date
      })

      {:ok, updated}
    end
  end

  @spec revoke_access(String.t()) :: :ok | {:error, term()}
  def revoke_access(employee_id) do
    with {:ok, employee} <- Repo.fetch(:employees, employee_id) do
      IdentityProvisioner.deprovision(employee)
      :ok
    end
  end

  @spec initiate_resignation(String.t(), Date.t()) :: {:ok, map()} | {:error, term()}
  def initiate_resignation(employee_id, last_day) do
    with {:ok, employee} <- Repo.fetch(:employees, employee_id),
         :ok <- validate_active(employee) do
      updated = Map.put(employee, :resignation_notice_date, Date.utc_today())
      Repo.update(:employees, employee_id, %{resignation_notice_date: Date.utc_today()})
      Notifier.notify_manager(employee, :resignation_received)
      {:ok, updated}
    end
  end

  defp run_offboarding_steps(employee, attrs) do
    Process.send_after(self(), {:revoke_access, employee.id}, @access_revocation_delay_hours * 3_600_000)
    final_pay_date = Map.get(attrs, :final_pay_date, Date.utc_today())
    Payroll.process_final_payment(employee, final_pay_date)
    EquipmentService.request_return(employee)
    Notifier.send_offboarding_instructions(employee)
    schedule_data_retention(employee.id)
  end

  defp schedule_data_retention(employee_id) do
    retain_until = Date.add(Date.utc_today(), @data_retention_years * 365)
    Repo.update(:employees, employee_id, %{data_retain_until: retain_until})
  end

  defp validate_active(%{status: :active}), do: :ok
  defp validate_active(_), do: {:error, :employee_not_active}
end
```
