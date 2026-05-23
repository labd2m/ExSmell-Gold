```elixir
defmodule HR.EmployeeRegistry do
  @moduledoc """
  Central registry for employee records. Handles lookups, inter-departmental
  transfers, leave recording, and payslip generation for the HR platform.
  """

  require Logger

  alias HR.Repo
  alias HR.Schema.{Employee, Department, LeaveRecord, Payslip}

  @employee_id_pattern ~r/^EMP-[A-Z]{2,6}-\d{4}$/
  @valid_leave_types ~w(annual sick parental unpaid)


  @spec lookup_employee(String.t()) :: {:ok, Employee.t()} | {:error, term()}
  def lookup_employee(employee_id) when is_binary(employee_id) do
    with :ok <- validate_employee_id_format(employee_id) do
      case Repo.get_by(Employee, employee_id: employee_id) do
        nil ->
          {:error, {:not_found, employee_id}}

        employee ->
          dept_code = extract_department_code(employee_id)
          Logger.debug("Lookup: id=#{employee_id} dept=#{dept_code}")
          {:ok, employee}
      end
    end
  end

  @spec transfer_department(String.t(), String.t(), Date.t()) ::
          {:ok, Employee.t()} | {:error, term()}
  def transfer_department(employee_id, new_department_code, effective_date)
      when is_binary(employee_id) and is_binary(new_department_code) do
    with :ok <- validate_employee_id_format(employee_id),
         {:ok, employee} <- lookup_employee(employee_id),
         {:ok, new_dept} <- fetch_department(new_department_code) do
      old_dept_code = extract_department_code(employee_id)
      sequence = extract_sequence_number(employee_id)
      new_id = "EMP-#{new_department_code}-#{String.pad_leading(Integer.to_string(sequence), 4, "0")}"

      Logger.info("Transfer: #{employee_id} (#{old_dept_code}) -> #{new_id} (#{new_department_code}) eff=#{effective_date}")

      employee
      |> Employee.changeset(%{
        employee_id: new_id,
        department_id: new_dept.id,
        transferred_at: effective_date
      })
      |> Repo.update()
    end
  end

  @spec record_leave(String.t(), String.t(), {Date.t(), Date.t()}) ::
          {:ok, LeaveRecord.t()} | {:error, term()}
  def record_leave(employee_id, leave_type, {start_date, end_date})
      when is_binary(employee_id) and is_binary(leave_type) do
    with :ok <- validate_employee_id_format(employee_id),
         :ok <- validate_leave_type(leave_type),
         {:ok, employee} <- lookup_employee(employee_id) do
      dept_code = extract_department_code(employee_id)

      attrs = %{
        employee_id: employee.id,
        employee_ref: employee_id,
        department_code: dept_code,
        leave_type: leave_type,
        start_date: start_date,
        end_date: end_date,
        days: Date.diff(end_date, start_date) + 1,
        applied_at: Date.utc_today()
      }

      %LeaveRecord{} |> LeaveRecord.changeset(attrs) |> Repo.insert()
    end
  end

  @spec generate_payslip(String.t(), Date.t()) ::
          {:ok, Payslip.t()} | {:error, term()}
  def generate_payslip(employee_id, pay_period) when is_binary(employee_id) do
    with :ok <- validate_employee_id_format(employee_id),
         {:ok, employee} <- lookup_employee(employee_id) do
      dept_code = extract_department_code(employee_id)
      seq = extract_sequence_number(employee_id)

      payslip_ref = "PAY-#{dept_code}-#{seq}-#{pay_period}"

      attrs = %{
        employee_id: employee.id,
        reference: payslip_ref,
        gross_amount: employee.salary,
        pay_period: pay_period,
        department_code: dept_code,
        generated_at: DateTime.utc_now()
      }

      %Payslip{} |> Payslip.changeset(attrs) |> Repo.insert()
    end
  end


  ## Private helpers

  defp validate_employee_id_format(id) do
    if Regex.match?(@employee_id_pattern, id) do
      :ok
    else
      {:error, {:invalid_employee_id_format, id}}
    end
  end

  defp extract_department_code(employee_id) when is_binary(employee_id) do
    employee_id |> String.split("-") |> Enum.at(1)
  end

  defp extract_sequence_number(employee_id) when is_binary(employee_id) do
    employee_id |> String.split("-") |> Enum.at(2) |> String.to_integer()
  end

  defp fetch_department(code) do
    case Repo.get_by(Department, code: code) do
      nil -> {:error, {:unknown_department, code}}
      dept -> {:ok, dept}
    end
  end

  defp validate_leave_type(type) when type in @valid_leave_types, do: :ok
  defp validate_leave_type(type), do: {:error, {:invalid_leave_type, type}}
end
```