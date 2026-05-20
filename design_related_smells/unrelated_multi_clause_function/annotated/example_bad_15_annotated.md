# Annotated Example 15

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `ScheduleManager.submit/1`
- **Affected function(s):** `submit/1`
- **Short explanation:** `submit/1` conflates appointment booking, shift scheduling, and maintenance window registration — three separate scheduling domains — into one multi-clause function, making it impossible to document each independently and burying domain intent.

```elixir
defmodule ScheduleManager do
  @moduledoc """
  Manages scheduling operations across the platform including customer
  appointments, staff shift scheduling, and infrastructure maintenance windows.
  """

  alias ScheduleManager.{
    AppointmentRequest,
    ShiftRequest,
    MaintenanceWindow,
    CalendarStore,
    StaffStore,
    InfrastructureRegistry,
    ConflictChecker,
    Notifier
  }

  require Logger

  @doc """
  Submit a scheduling request.

  Accepts a `%AppointmentRequest{}`, `%ShiftRequest{}`, or
  `%MaintenanceWindow{}` and reserves the corresponding time slot.

  ## Examples

      iex> ScheduleManager.submit(%AppointmentRequest{customer_id: 1, service: :consultation, at: ~N[2024-06-15 14:00:00]})
      {:ok, %{appointment_id: "appt_abc123", confirmed_at: ~U[...]}}

  """
  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because customer appointment booking, employee
  # shift scheduling, and infrastructure maintenance windows are completely
  # different concerns—different stakeholders, different conflict rules, and
  # different notification targets—yet they are all handled by the same
  # `submit/1` multi-clause function.

  def submit(%AppointmentRequest{
        customer_id: customer_id,
        service: service,
        at: at,
        provider_id: provider_id,
        notes: notes
      }) do
    slot = %{provider_id: provider_id, starts_at: at, duration: service_duration(service)}

    with :ok <- ConflictChecker.check_provider_availability(slot),
         {:ok, appt} <-
           CalendarStore.create_appointment(%{
             customer_id: customer_id,
             provider_id: provider_id,
             service: service,
             starts_at: at,
             ends_at: DateTime.add(at, service_duration(service), :minute),
             notes: notes,
             status: :confirmed
           }),
         :ok <- Notifier.send_appointment_confirmation(customer_id, appt),
         :ok <- Notifier.send_provider_notification(provider_id, appt) do
      Logger.info("Appointment #{appt.id} booked for customer #{customer_id}")
      {:ok, %{appointment_id: appt.id, confirmed_at: appt.inserted_at}}
    end
  end

  # submit staff shift scheduling request from manager
  def submit(%ShiftRequest{
        employee_id: employee_id,
        location_id: location_id,
        role: role,
        starts_at: starts_at,
        ends_at: ends_at,
        submitted_by: manager_id
      }) do
    with {:ok, employee} <- StaffStore.find(employee_id),
         :ok <- validate_role_qualified(employee, role),
         :ok <- ConflictChecker.check_employee_availability(employee_id, starts_at, ends_at),
         {:ok, shift} <-
           CalendarStore.create_shift(%{
             employee_id: employee_id,
             location_id: location_id,
             role: role,
             starts_at: starts_at,
             ends_at: ends_at,
             created_by: manager_id
           }),
         :ok <- Notifier.send_shift_assignment(employee_id, shift) do
      Logger.info(
        "Shift #{shift.id} assigned to employee #{employee_id} by manager #{manager_id}"
      )

      {:ok, shift}
    end
  end

  # submit infrastructure maintenance window for planned downtime
  def submit(%MaintenanceWindow{
        service_name: service_name,
        starts_at: starts_at,
        ends_at: ends_at,
        description: description,
        owner: owner
      }) do
    with :ok <- validate_future_window(starts_at),
         {:ok, service} <- InfrastructureRegistry.find_service(service_name),
         :ok <- ConflictChecker.check_maintenance_conflicts(service.id, starts_at, ends_at),
         {:ok, window} <-
           CalendarStore.create_maintenance_window(%{
             service_id: service.id,
             service_name: service_name,
             starts_at: starts_at,
             ends_at: ends_at,
             description: description,
             owner: owner,
             status: :scheduled
           }),
         :ok <- Notifier.broadcast_maintenance_notice(window) do
      Logger.info("Maintenance window #{window.id} scheduled for #{service_name}")
      {:ok, window}
    end
  end

  # VALIDATION: SMELL END

  defp service_duration(:consultation), do: 30
  defp service_duration(:full_service), do: 60
  defp service_duration(:quick_check), do: 15
  defp service_duration(_), do: 30

  defp validate_role_qualified(employee, role) do
    if role in employee.qualified_roles do
      :ok
    else
      {:error, {:not_qualified_for_role, role}}
    end
  end

  defp validate_future_window(starts_at) do
    if DateTime.compare(starts_at, DateTime.utc_now()) == :gt do
      :ok
    else
      {:error, :maintenance_window_must_be_in_future}
    end
  end
end
```
