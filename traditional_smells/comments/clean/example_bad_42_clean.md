```elixir
defmodule AppointmentScheduler do
  @moduledoc """
  Manages appointment scheduling, availability checks, and calendar
  synchronisation for the telemedicine platform.
  """

  alias AppointmentScheduler.{Appointment, CalendarRepo, Provider, SlotCalculator}
  require Logger

  @slot_duration_minutes 30
  @max_advance_booking_days 90

  @doc """
  Returns available appointment slots for a given provider and date.
  Each slot is represented as a `%{start: DateTime, end: DateTime}` map.
  """
  def available_slots(provider_id, %Date{} = date) when is_binary(provider_id) do
    with {:ok, %Provider{} = provider} <- CalendarRepo.fetch_provider(provider_id),
         {:ok, existing} <- CalendarRepo.fetch_appointments(provider_id, date) do
      SlotCalculator.calculate(provider.schedule, existing, date, @slot_duration_minutes)
    end
  end

  @doc """
  Cancels an existing appointment by ID and notifies the affected provider and patient.
  """
  def cancel_appointment(appointment_id, reason \\ nil) when is_binary(appointment_id) do
    with {:ok, %Appointment{} = appt} <- CalendarRepo.fetch_appointment(appointment_id) do
      CalendarRepo.update_appointment(appointment_id, %{status: :cancelled, cancel_reason: reason})
      notify_cancellation(appt)
    end
  end

  # Books an appointment slot for a patient with the specified provider.
  #
  # Parameters:
  #   provider_id  - binary, the unique identifier of the healthcare provider
  #   patient_id   - binary, the unique identifier of the patient
  #   slot         - map with keys :start (DateTime) and :end (DateTime)
  #
  # Validations performed:
  #   - The slot must be available (no conflicting appointments)
  #   - The appointment must be within @max_advance_booking_days from today
  #   - Both provider and patient must exist in the system
  #
  # Returns {:ok, %Appointment{}} on success.
  # Returns {:error, :slot_unavailable} if the slot is already taken.
  # Returns {:error, :too_far_in_advance} if start date exceeds the booking window.
  # Returns {:error, :provider_not_found | :patient_not_found} for unknown IDs.
  def book_appointment(provider_id, patient_id, %{start: start_dt, end: end_dt} = slot)
      when is_binary(provider_id) and is_binary(patient_id) do
    with :ok <- check_booking_window(start_dt),
         {:ok, _provider} <- CalendarRepo.fetch_provider(provider_id),
         {:ok, _patient} <- CalendarRepo.fetch_patient(patient_id),
         :ok <- check_slot_availability(provider_id, slot) do
      appointment = %Appointment{
        provider_id: provider_id,
        patient_id: patient_id,
        start_at: start_dt,
        end_at: end_dt,
        status: :confirmed,
        booked_at: DateTime.utc_now()
      }

      CalendarRepo.insert_appointment(appointment)
    end
  end

  @doc """
  Reschedules an existing appointment to a new time slot, subject to the same
  availability constraints as `book_appointment/3`.
  """
  def reschedule_appointment(appointment_id, new_slot)
      when is_binary(appointment_id) and is_map(new_slot) do
    with {:ok, %Appointment{provider_id: provider_id, patient_id: patient_id}} <-
           CalendarRepo.fetch_appointment(appointment_id),
         :ok <- cancel_appointment(appointment_id, "rescheduled") do
      book_appointment(provider_id, patient_id, new_slot)
    end
  end

  @doc """
  Lists all upcoming appointments for a patient within the next N days.
  """
  def upcoming_appointments(patient_id, days \\ 7) when is_binary(patient_id) do
    cutoff = Date.add(Date.utc_today(), days)
    CalendarRepo.list_appointments_for_patient(patient_id, until: cutoff)
  end

  defp check_booking_window(%DateTime{} = start_dt) do
    max_date = Date.add(Date.utc_today(), @max_advance_booking_days)

    if Date.compare(DateTime.to_date(start_dt), max_date) == :gt do
      {:error, :too_far_in_advance}
    else
      :ok
    end
  end

  defp check_slot_availability(provider_id, %{start: start_dt, end: end_dt}) do
    date = DateTime.to_date(start_dt)

    case CalendarRepo.fetch_appointments(provider_id, date) do
      {:ok, existing} ->
        conflict =
          Enum.any?(existing, fn appt ->
            DateTime.compare(appt.start_at, end_dt) == :lt and
              DateTime.compare(appt.end_at, start_dt) == :gt
          end)

        if conflict, do: {:error, :slot_unavailable}, else: :ok

      error ->
        error
    end
  end

  defp notify_cancellation(%Appointment{} = appt) do
    Logger.info("Appointment #{appt.id} cancelled. Notifying participants.")
  end
end
```
