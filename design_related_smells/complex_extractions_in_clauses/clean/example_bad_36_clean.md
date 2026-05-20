```elixir
defmodule Scheduling.AppointmentBook do
  @moduledoc """
  Manages the booking and confirmation of medical appointments.
  Routes requests based on appointment type to the correct provider pool,
  availability engine, insurance verifier, and notification pathway.
  """

  alias Scheduling.{ProviderPool, AvailabilityEngine, CalendarService, NotificationService, InsuranceVerifier}
  require Logger

  @confirmation_window_days 2

  def book(request_id) do
    with {:ok, appointment} <- CalendarService.fetch_request(request_id),
         {:ok, confirmation} <- confirm_appointment(appointment) do
      CalendarService.save_confirmation(request_id, confirmation)
      {:ok, confirmation}
    else
      {:error, :no_availability} ->
        Logger.warning("No availability found for request=#{request_id}")
        {:error, :no_availability}

      {:error, :insurance_rejected} ->
        Logger.warning("Insurance verification failed for request=#{request_id}")
        {:error, :insurance_rejected}

      {:error, reason} ->
        Logger.error("Booking failed for request=#{request_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # extracting eight fields from %Appointment{} in the function head (type,
  # duration_minutes, patient_id, provider_id, preferred_date, location, notes,
  # insurance_id). Only `type` is used in pattern matching to select the clause.
  # The remaining seven fields (duration_minutes, patient_id, provider_id,
  # preferred_date, location, notes, insurance_id) are referenced exclusively inside
  # the function bodies. The extraction of all these body-only bindings in every clause
  # head creates significant visual noise and makes the dispatch condition —just `type`—
  # very hard to spot without carefully scanning all three heads.

  def confirm_appointment(%Appointment{
        type: type,
        duration_minutes: duration_minutes,
        patient_id: patient_id,
        provider_id: provider_id,
        preferred_date: preferred_date,
        location: location,
        notes: notes,
        insurance_id: insurance_id
      })
      when type == :consultation do
    :ok = InsuranceVerifier.verify!(insurance_id, :consultation)
    slot = AvailabilityEngine.find_slot(provider_id, preferred_date, duration_minutes)

    CalendarService.block_slot(slot, %{
      patient_id: patient_id,
      provider_id: provider_id,
      location: location,
      notes: notes
    })

    NotificationService.send_confirmation(patient_id, %{
      type: :consultation,
      slot: slot,
      location: location,
      duration_minutes: duration_minutes
    })

    {:ok, %{type: :consultation, slot: slot, provider_id: provider_id}}
  end

  def confirm_appointment(%Appointment{
        type: type,
        duration_minutes: duration_minutes,
        patient_id: patient_id,
        provider_id: provider_id,
        preferred_date: preferred_date,
        location: location,
        notes: notes,
        insurance_id: insurance_id
      })
      when type == :follow_up do
    prior_visit = CalendarService.fetch_last_visit(patient_id, provider_id)
    slot = AvailabilityEngine.find_slot(provider_id, preferred_date, duration_minutes)

    CalendarService.block_slot(slot, %{
      patient_id: patient_id,
      provider_id: provider_id,
      location: location,
      notes: "Follow-up (#{prior_visit.id}): #{notes}"
    })

    NotificationService.send_confirmation(patient_id, %{
      type: :follow_up,
      slot: slot,
      location: location,
      duration_minutes: duration_minutes,
      prior_visit_date: prior_visit.date
    })

    {:ok, %{type: :follow_up, slot: slot, provider_id: provider_id}}
  end

  def confirm_appointment(%Appointment{
        type: type,
        duration_minutes: duration_minutes,
        patient_id: patient_id,
        provider_id: provider_id,
        preferred_date: preferred_date,
        location: location,
        notes: notes,
        insurance_id: insurance_id
      })
      when type == :urgent do
    :ok = InsuranceVerifier.verify!(insurance_id, :urgent)
    provider = ProviderPool.assign_urgent(preferred_date)
    slot = AvailabilityEngine.find_urgent_slot(provider.id, preferred_date, duration_minutes)

    CalendarService.block_slot(slot, %{
      patient_id: patient_id,
      provider_id: provider_id,
      location: location,
      notes: notes,
      priority: :urgent
    })

    NotificationService.send_urgent_confirmation(patient_id, %{
      type: :urgent,
      slot: slot,
      location: location,
      provider: provider,
      duration_minutes: duration_minutes
    })

    {:ok, %{type: :urgent, slot: slot, provider_id: provider.id}}
  end


  def confirm_appointment(%Appointment{type: type, patient_id: patient_id}) do
    Logger.warning("Unsupported appointment type=#{type} for patient=#{patient_id}")
    {:error, {:unsupported_type, type}}
  end

  defp within_confirmation_window?(preferred_date) do
    Date.diff(preferred_date, Date.utc_today()) <= @confirmation_window_days
  end
end
```
