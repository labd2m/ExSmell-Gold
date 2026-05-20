# Annotated Example — Smell: Unrelated multi-clause function

## Metadata

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `SchedulingEngine.apply/1`
- **Affected function(s):** `apply/1`
- **Short explanation:** The `apply/1` function overloads three unrelated scheduling operations: booking an appointment, cancelling a shift for a staff member, and publishing a recurring maintenance window. These are distinct domain actions that affect different entities, trigger different notifications, enforce different business rules, and should each have their own named function. Combining them under `apply/1` creates an opaque entry point that is difficult to document, test, and evolve.

---

```elixir
defmodule MyApp.SchedulingEngine do
  @moduledoc """
  Manages scheduling operations for appointments, staff shifts,
  and maintenance windows in the platform.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Scheduling.{Appointment, StaffShift, MaintenanceWindow}
  alias MyApp.Accounts.User
  alias MyApp.Notifications.Mailer
  alias MyApp.Calendar.ConflictChecker

  @min_advance_booking_hours 1
  @shift_cancel_notice_hours 4
  @maintenance_min_duration_minutes 15

  @doc """
  Applies a scheduling action.

  Accepts one of:
  - `%Appointment{}`
  - `%StaffShift{action: :cancel, ...}`
  - `%MaintenanceWindow{status: :draft, ...}`

  ## Examples

      iex> MyApp.SchedulingEngine.apply(%Appointment{starts_at: ~U[2024-06-01 10:00:00Z], ...})
      {:ok, %Appointment{status: :confirmed}}

  """

  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because the three clauses apply completely
  # unrelated scheduling actions (booking an appointment, cancelling a staff
  # shift, and publishing a maintenance window). Each enforces different business
  # rules, touches different schemas, and triggers different notifications.
  # Forcing them into a single multi-clause function hides intent and makes
  # isolated documentation and testing impossible.

  def apply(
        %Appointment{
          status: :pending,
          starts_at: starts_at,
          provider_id: provider_id,
          patient_id: patient_id,
          service_type: service_type
        } = appointment
      ) do
    now = DateTime.utc_now()
    hours_until = DateTime.diff(starts_at, now, :second) / 3600.0

    cond do
      hours_until < @min_advance_booking_hours ->
        Logger.warn("Appointment too close to start time for patient #{patient_id}")
        {:error, :too_late_to_book}

      ConflictChecker.has_conflict?(provider_id, starts_at, service_duration(service_type)) ->
        Logger.warn("Provider #{provider_id} has a conflict at #{starts_at}")
        {:error, :provider_conflict}

      true ->
        {:ok, confirmed} =
          Repo.update(
            Appointment.changeset(appointment, %{
              status: :confirmed,
              confirmed_at: now
            })
          )

        Mailer.send_appointment_confirmation(patient_id, confirmed)
        Mailer.send_provider_booking_alert(provider_id, confirmed)
        Logger.info("Appointment #{confirmed.id} confirmed for patient #{patient_id}")
        {:ok, confirmed}
    end
  end

  def apply(
        %StaffShift{
          action: :cancel,
          staff_id: staff_id,
          shift_date: shift_date,
          start_time: start_time,
          status: :scheduled
        } = shift
      ) do
    shift_start_naive = NaiveDateTime.new!(shift_date, start_time)
    shift_start_utc = DateTime.from_naive!(shift_start_naive, "Etc/UTC")
    hours_until = DateTime.diff(shift_start_utc, DateTime.utc_now(), :second) / 3600.0

    staff = Repo.get!(User, staff_id)

    if hours_until < @shift_cancel_notice_hours do
      Logger.warn("Staff #{staff_id} cancelling shift with less than #{@shift_cancel_notice_hours}h notice")

      {:ok, updated} =
        Repo.update(
          StaffShift.changeset(shift, %{
            status: :cancelled,
            cancellation_reason: :short_notice,
            cancelled_at: DateTime.utc_now()
          })
        )

      Mailer.notify_scheduling_manager_late_cancellation(staff, updated)
      {:ok, %{updated | penalty_flag: true}}
    else
      {:ok, updated} =
        Repo.update(
          StaffShift.changeset(shift, %{
            status: :cancelled,
            cancellation_reason: :standard,
            cancelled_at: DateTime.utc_now()
          })
        )

      Mailer.notify_scheduling_manager_cancellation(staff, updated)
      Logger.info("Staff shift for #{staff_id} on #{shift_date} cancelled cleanly")
      {:ok, updated}
    end
  end

  def apply(
        %MaintenanceWindow{
          status: :draft,
          starts_at: starts_at,
          ends_at: ends_at,
          affected_services: services,
          created_by: admin_id
        } = window
      ) do
    duration_mins = DateTime.diff(ends_at, starts_at, :second) / 60

    cond do
      DateTime.compare(starts_at, DateTime.utc_now()) != :gt ->
        Logger.warn("Maintenance window #{window.id} has a past start time")
        {:error, :start_time_in_past}

      duration_mins < @maintenance_min_duration_minutes ->
        Logger.warn("Maintenance window #{window.id} duration too short: #{duration_mins} min")
        {:error, :duration_too_short}

      services == [] ->
        Logger.warn("Maintenance window #{window.id} has no affected services listed")
        {:error, :no_services_specified}

      true ->
        {:ok, published} =
          Repo.update(
            MaintenanceWindow.changeset(window, %{
              status: :published,
              published_at: DateTime.utc_now(),
              published_by: admin_id
            })
          )

        Mailer.broadcast_maintenance_notice(published)
        Logger.info("Maintenance window #{published.id} published by admin #{admin_id}")
        {:ok, published}
    end
  end

  # VALIDATION: SMELL END

  defp service_duration(:consultation), do: 30
  defp service_duration(:procedure), do: 60
  defp service_duration(:follow_up), do: 15
  defp service_duration(_), do: 45
end
```
