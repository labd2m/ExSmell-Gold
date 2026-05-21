```elixir
defmodule AppointmentBook do
  @moduledoc """
  Manages scheduling of appointments against provider calendars.
  Handles slot availability, business-hours enforcement, and conflict detection.
  """

  defmodule SlotConflictError do
    defexception [:message, :provider_id, :requested_start, :conflicting_appointment_id]
  end

  defmodule OutsideBusinessHoursError do
    defexception [:message, :requested_start, :provider_id]
  end

  defmodule UnknownProviderError do
    defexception [:message, :provider_id]
  end

  defmodule InvalidDurationError do
    defexception [:message, :duration_minutes]
  end

  @business_hours_start 8
  @business_hours_end 18

  @providers %{
    "prov-001" => %{name: "Dr. Smith", timezone: "America/New_York", slot_duration_min: 30},
    "prov-002" => %{name: "Dr. Jones", timezone: "America/Chicago", slot_duration_min: 60}
  }

  @existing_appointments [
    %{id: "appt-100", provider_id: "prov-001", start: ~U[2025-09-15 14:00:00Z], duration_min: 30},
    %{id: "appt-101", provider_id: "prov-002", start: ~U[2025-09-15 16:00:00Z], duration_min: 60}
  ]

  def schedule(%{provider_id: provider_id, start: start, duration_minutes: duration_minutes, patient_id: _patient_id} = appointment) do
    provider = Map.get(@providers, provider_id)

    if is_nil(provider) do
      raise UnknownProviderError,
        message: "No provider registered with ID '#{provider_id}'",
        provider_id: provider_id
    end

    unless is_integer(duration_minutes) and duration_minutes > 0 and duration_minutes <= 240 do
      raise InvalidDurationError,
        message: "Duration must be between 1 and 240 minutes, got: #{inspect(duration_minutes)}",
        duration_minutes: duration_minutes
    end

    start_hour = start.hour

    if start_hour < @business_hours_start or start_hour >= @business_hours_end do
      raise OutsideBusinessHoursError,
        message:
          "Requested time #{start} is outside business hours " <>
            "(#{@business_hours_start}:00–#{@business_hours_end}:00) for provider #{provider_id}",
        requested_start: start,
        provider_id: provider_id
    end

    conflict = find_conflict(provider_id, start, duration_minutes)

    if conflict do
      raise SlotConflictError,
        message:
          "Time slot at #{start} for provider #{provider_id} conflicts with appointment #{conflict.id}",
        provider_id: provider_id,
        requested_start: start,
        conflicting_appointment_id: conflict.id
    end

    %{
      id: "appt-#{System.unique_integer([:positive])}",
      provider_id: provider_id,
      provider_name: provider.name,
      start: start,
      end: DateTime.add(start, duration_minutes * 60, :second),
      duration_minutes: duration_minutes,
      status: :confirmed,
      booked_at: DateTime.utc_now()
    }
  end

  def schedule(_params) do
    raise ArgumentError,
      message: "Appointment must include :provider_id, :start, :duration_minutes, and :patient_id"
  end

  defp find_conflict(provider_id, start, duration_min) do
    end_time = DateTime.add(start, duration_min * 60, :second)

    Enum.find(@existing_appointments, fn appt ->
      appt.provider_id == provider_id and
        DateTime.compare(appt.start, end_time) == :lt and
        DateTime.compare(DateTime.add(appt.start, appt.duration_min * 60, :second), start) == :gt
    end)
  end
end

defmodule BookingService do
  @moduledoc """
  Orchestrates appointment booking on behalf of patients.
  Integrates with calendar synchronisation and notification systems.
  """

  require Logger

  def book(patient_id, %{provider_id: _, start: _, duration_minutes: _} = request) do
    Logger.info("Patient #{patient_id} requesting appointment with #{request.provider_id}")

    appointment_params = Map.put(request, :patient_id, patient_id)

    # exceptions for things like a booked-out slot or an after-hours request —
    # both of which are expected scheduling outcomes and not truly exceptional.
    try do
      appointment = AppointmentBook.schedule(appointment_params)

      Logger.info(
        "Appointment #{appointment.id} confirmed with #{appointment.provider_name} at #{appointment.start}"
      )

      {:ok, appointment}
    rescue
      e in AppointmentBook.SlotConflictError ->
        Logger.info(
          "Slot conflict for patient #{patient_id}: #{e.requested_start} taken (#{e.conflicting_appointment_id})"
        )
        {:error, :slot_conflict, e.conflicting_appointment_id}

      e in AppointmentBook.OutsideBusinessHoursError ->
        Logger.warning("Patient #{patient_id} requested out-of-hours slot: #{e.requested_start}")
        {:error, :outside_hours}

      e in AppointmentBook.UnknownProviderError ->
        Logger.error("Unknown provider #{e.provider_id} requested by patient #{patient_id}")
        {:error, :unknown_provider}

      e in AppointmentBook.InvalidDurationError ->
        Logger.warning("Invalid duration: #{e.message}")
        {:error, :invalid_duration}
    end
  end
end
```
