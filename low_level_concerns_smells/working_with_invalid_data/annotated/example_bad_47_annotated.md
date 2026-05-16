# Example 47: Appointment Scheduling and Capacity Management - Annotated

## Metadata
- **Smell Name**: Working with invalid data
- **Expected Location**: `Scheduling.AppointmentManager.book_appointment/5` function
- **Affected Functions**: `book_appointment/5`
- **Explanation**: The function does not validate that `duration_minutes` is an integer before passing it to `DateTime.add/3`. If a string or atom is supplied, the error surfaces inside the DateTime module rather than at the public function boundary.

## Code

```elixir
defmodule Scheduling.AppointmentManager do
  @moduledoc """
  Manages appointment booking, provider availability, capacity windows,
  and scheduling conflicts for a multi-location healthcare practice platform.
  """

  alias Scheduling.{Provider, Patient, Appointment, AvailabilityWindow, Location, Notification, AuditLog}

  @buffer_minutes 10
  @max_advance_booking_days 90
  @cancellation_cutoff_hours 24

  def fetch_available_slots(provider_id, date, service_type) do
    with {:ok, provider} <- Provider.get(provider_id),
         :ok <- validate_provider_offers_service(provider, service_type),
         {:ok, windows} <- AvailabilityWindow.list_for_provider_on_date(provider_id, date),
         {:ok, existing} <- Appointment.list_confirmed_for_provider_on_date(provider_id, date) do

      booked_ranges = Enum.map(existing, fn a ->
        {a.start_time, DateTime.add(a.start_time, a.duration_minutes * 60, :second)}
      end)

      slots =
        windows
        |> Enum.flat_map(&generate_slots(&1, service_type.default_duration_minutes))
        |> Enum.reject(fn slot -> overlaps_any?(slot, booked_ranges) end)
        |> Enum.map(&format_slot/1)

      {:ok, %{provider_id: provider_id, date: date, available_slots: slots}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # VALIDATION: SMELL START - Working with invalid data
  # VALIDATION: This is a smell because `duration_minutes` is not validated to be
  # VALIDATION: an integer before being multiplied by 60 and passed to DateTime.add/3.
  # VALIDATION: If a caller passes "45" (a string) or :standard (an atom), the error
  # VALIDATION: will surface inside `DateTime.add/3` or the multiplication expression
  # VALIDATION: rather than at the boundary of this public function.
  def book_appointment(patient_id, provider_id, start_time, duration_minutes, service_type) do
    with {:ok, patient} <- Patient.get(patient_id),
         {:ok, provider} <- Provider.get(provider_id),
         :ok <- validate_provider_offers_service(provider, service_type),
         :ok <- validate_advance_booking(start_time),
         :ok <- validate_no_patient_conflict(patient_id, start_time, duration_minutes) do

      # No validation on duration_minutes before arithmetic and DateTime.add/3
      end_time = DateTime.add(start_time, duration_minutes * 60, :second)

      with :ok <- validate_slot_available(provider_id, start_time, end_time) do
        appointment = %Appointment{
          id: generate_appointment_id(),
          patient_id: patient_id,
          provider_id: provider_id,
          location_id: provider.primary_location_id,
          service_type: service_type,
          start_time: start_time,
          end_time: end_time,
          duration_minutes: duration_minutes,
          status: :confirmed,
          booked_at: DateTime.utc_now()
        }

        {:ok, _} = Appointment.insert(appointment)
        {:ok, _} = Notification.send(patient_id, :appointment_confirmed, appointment)
        {:ok, _} = Notification.send(provider_id, :new_appointment, appointment)
        {:ok, _} = AuditLog.record(:appointment_booked, patient_id, %{appointment_id: appointment.id})

        {:ok, appointment}
      else
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end
  # VALIDATION: SMELL END

  def reschedule_appointment(appointment_id, new_start_time, reason) do
    with {:ok, appointment} <- Appointment.get(appointment_id),
         :ok <- validate_cancellation_window(appointment),
         :ok <- validate_advance_booking(new_start_time),
         :ok <- validate_no_patient_conflict(appointment.patient_id, new_start_time, appointment.duration_minutes) do

      new_end_time = DateTime.add(new_start_time, appointment.duration_minutes * 60, :second)

      with :ok <- validate_slot_available(appointment.provider_id, new_start_time, new_end_time) do
        {:ok, _} = Appointment.update(appointment_id, %{
          start_time: new_start_time,
          end_time: new_end_time,
          status: :confirmed,
          rescheduled_at: DateTime.utc_now(),
          reschedule_reason: reason
        })

        {:ok, updated} = Appointment.get(appointment_id)
        {:ok, _} = Notification.send(appointment.patient_id, :appointment_rescheduled, updated)

        {:ok, updated}
      else
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def cancel_appointment(appointment_id, cancelled_by, reason) do
    with {:ok, appointment} <- Appointment.get(appointment_id),
         :ok <- validate_cancellable(appointment),
         :ok <- validate_cancellation_window(appointment) do

      {:ok, _} = Appointment.update(appointment_id, %{
        status: :cancelled,
        cancelled_at: DateTime.utc_now(),
        cancelled_by: cancelled_by,
        cancellation_reason: reason
      })

      {:ok, _} = Notification.send(appointment.patient_id, :appointment_cancelled, appointment)
      {:ok, _} = Notification.send(appointment.provider_id, :appointment_cancelled, appointment)

      {:ok, :cancelled}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def get_provider_schedule(provider_id, date) do
    with {:ok, provider} <- Provider.get(provider_id),
         {:ok, appointments} <- Appointment.list_confirmed_for_provider_on_date(provider_id, date),
         {:ok, windows} <- AvailabilityWindow.list_for_provider_on_date(provider_id, date) do

      total_booked_minutes = Enum.sum(Enum.map(appointments, & &1.duration_minutes))
      total_available_minutes = Enum.sum(Enum.map(windows, & &1.duration_minutes))

      {:ok, %{
        provider_id: provider_id,
        provider_name: provider.full_name,
        date: date,
        appointments: Enum.map(appointments, &summarize_appointment/1),
        total_booked_minutes: total_booked_minutes,
        total_available_minutes: total_available_minutes,
        utilisation_pct: if(total_available_minutes > 0, do: total_booked_minutes / total_available_minutes * 100, else: 0)
      }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_slots(%AvailabilityWindow{} = window, duration_minutes) do
    slot_duration_secs = (duration_minutes + @buffer_minutes) * 60
    total_secs = DateTime.diff(window.end_time, window.start_time, :second)
    num_slots = div(total_secs, slot_duration_secs)

    Enum.map(0..(num_slots - 1), fn i ->
      slot_start = DateTime.add(window.start_time, i * slot_duration_secs, :second)
      slot_end = DateTime.add(slot_start, duration_minutes * 60, :second)
      {slot_start, slot_end}
    end)
  end

  defp overlaps_any?({start, end_t}, booked_ranges) do
    Enum.any?(booked_ranges, fn {bs, be} ->
      DateTime.compare(start, be) == :lt and DateTime.compare(end_t, bs) == :gt
    end)
  end

  defp validate_slot_available(provider_id, start_time, end_time) do
    case Appointment.find_overlapping_for_provider(provider_id, start_time, end_time) do
      {:ok, []} -> :ok
      {:ok, _} -> {:error, :slot_no_longer_available}
      error -> error
    end
  end

  defp validate_no_patient_conflict(patient_id, start_time, duration_minutes) do
    end_time = DateTime.add(start_time, duration_minutes * 60, :second)
    case Appointment.find_overlapping_for_patient(patient_id, start_time, end_time) do
      {:ok, []} -> :ok
      {:ok, _} -> {:error, :patient_has_conflicting_appointment}
      error -> error
    end
  end

  defp validate_advance_booking(start_time) do
    days_ahead = DateTime.diff(start_time, DateTime.utc_now(), :second) / 86_400
    cond do
      days_ahead < 0 -> {:error, :appointment_in_the_past}
      days_ahead > @max_advance_booking_days -> {:error, :too_far_in_advance}
      true -> :ok
    end
  end

  defp validate_cancellation_window(appointment) do
    hours_until = DateTime.diff(appointment.start_time, DateTime.utc_now(), :second) / 3600
    if hours_until >= @cancellation_cutoff_hours, do: :ok, else: {:error, :past_cancellation_cutoff}
  end

  defp validate_cancellable(%{status: :confirmed}), do: :ok
  defp validate_cancellable(_), do: {:error, :appointment_not_cancellable}

  defp validate_provider_offers_service(provider, service_type) do
    if service_type.code in provider.offered_service_codes, do: :ok, else: {:error, :provider_does_not_offer_service}
  end

  defp format_slot({start_time, end_time}) do
    %{start_time: start_time, end_time: end_time}
  end

  defp summarize_appointment(a) do
    %{id: a.id, patient_id: a.patient_id, start: a.start_time, end: a.end_time, service: a.service_type, status: a.status}
  end

  defp generate_appointment_id, do: "appt_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
end
```
