# Annotated Example 35

- **Smell name:** Complex Branching
- **Expected smell location:** `book_appointment/2` function, the `case` expression over the scheduling API response
- **Affected function(s):** `book_appointment/2`
- **Short explanation:** All possible scheduling API outcomes — confirmed, waitlisted, slot conflicts, provider unavailability, patient limit reached, insurance authorization failures, and connectivity issues — are packed into one large `case` inside a single function, making it excessively complex and hard to extend or test per outcome.

```elixir
defmodule Scheduling.AppointmentService do
  @moduledoc """
  Books, reschedules, and cancels appointments via the MedSchedule API.
  Handles availability checking, patient eligibility, and insurance pre-authorization.
  """

  require Logger

  alias Scheduling.Repo
  alias Scheduling.Schema.{Appointment, Patient, Provider}
  alias Scheduling.MedSchedule.Client
  alias Scheduling.Notifications

  @appointment_types [:consultation, :follow_up, :procedure, :telehealth]

  def create(patient_id, provider_id, requested_at, type \\ :consultation)
      when type in @appointment_types do
    with {:ok, patient} <- fetch_patient(patient_id),
         {:ok, provider} <- fetch_provider(provider_id),
         :ok <- check_patient_eligibility(patient),
         {:ok, slot} <- Client.find_next_slot(provider.external_id, requested_at, type) do
      book_appointment(patient, Client.reserve(slot.id, patient.external_id, type))
    end
  end

  defp fetch_patient(id) do
    case Repo.get(Patient, id) do
      nil -> {:error, :patient_not_found}
      p -> {:ok, p}
    end
  end

  defp fetch_provider(id) do
    case Repo.get(Provider, id) do
      nil -> {:error, :provider_not_found}
      p -> {:ok, p}
    end
  end

  defp check_patient_eligibility(%Patient{status: :inactive}), do: {:error, :patient_inactive}
  defp check_patient_eligibility(%Patient{status: :suspended}), do: {:error, :patient_suspended}
  defp check_patient_eligibility(_), do: :ok

  # VALIDATION: SMELL START - Complex Branching
  # VALIDATION: This is a smell because the function handles all possible
  # responses from the MedSchedule reservation endpoint inside a single case
  # expression with many branches. Each branch represents a distinct business
  # outcome — confirmed booking, waitlist, slot conflict, unavailability, limit
  # breach, insurance issues, network problems — significantly increasing
  # cyclomatic complexity and making the function difficult to maintain or test.
  defp book_appointment(patient, scheduling_response) do
    case scheduling_response do
      {:ok, %{status: 201, body: %{"appointment_id" => appt_id, "status" => "confirmed", "starts_at" => starts_at}}} ->
        Logger.info("Appointment #{appt_id} confirmed for patient #{patient.id} at #{starts_at}")

        {:ok, record} =
          Repo.insert(%Appointment{
            patient_id: patient.id,
            external_id: appt_id,
            starts_at: starts_at,
            status: :confirmed
          })

        Notifications.send_booking_confirmation(patient, record)
        {:ok, record}

      {:ok, %{status: 202, body: %{"appointment_id" => appt_id, "status" => "waitlisted", "position" => pos}}} ->
        Logger.info("Patient #{patient.id} waitlisted at position #{pos} for appt #{appt_id}")

        {:ok, record} =
          Repo.insert(%Appointment{
            patient_id: patient.id,
            external_id: appt_id,
            status: :waitlisted,
            waitlist_position: pos
          })

        Notifications.send_waitlist_confirmation(patient, record)
        {:ok, record}

      {:ok, %{status: 409, body: %{"error" => "slot_conflict"}}} ->
        Logger.warning("Slot conflict for patient #{patient.id}")
        {:error, :slot_conflict}

      {:ok, %{status: 409, body: %{"error" => "patient_has_overlapping_appointment"}}} ->
        Logger.warning("Patient #{patient.id} already has an overlapping appointment")
        {:error, :overlapping_appointment}

      {:ok, %{status: 422, body: %{"error" => "provider_unavailable", "next_available" => next}}} ->
        Logger.info("Provider unavailable for patient #{patient.id}, next slot: #{next}")
        {:error, {:provider_unavailable, next}}

      {:ok, %{status: 422, body: %{"error" => "patient_limit_reached"}}} ->
        Logger.warning("Provider has reached patient limit, blocking booking for #{patient.id}")
        {:error, :patient_limit_reached}

      {:ok, %{status: 402, body: %{"error" => "insurance_authorization_required", "auth_code" => code}}} ->
        Logger.warning("Insurance pre-auth required for patient #{patient.id}, code #{code}")
        {:error, {:insurance_auth_required, code}}

      {:ok, %{status: 402, body: %{"error" => "insurance_not_accepted"}}} ->
        Logger.warning("Insurance not accepted by provider for patient #{patient.id}")
        {:error, :insurance_not_accepted}

      {:ok, %{status: 404, body: %{"error" => "slot_no_longer_available"}}} ->
        Logger.warning("Selected slot no longer available for patient #{patient.id}")
        {:error, :slot_expired}

      {:ok, %{status: 429, body: _}} ->
        Logger.warning("Rate limited by MedSchedule for patient #{patient.id}")
        {:error, :rate_limited}

      {:ok, %{status: 503, body: _}} ->
        Logger.error("MedSchedule unavailable for patient #{patient.id}")
        {:error, :scheduler_unavailable}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Unexpected MedSchedule status #{status} for patient #{patient.id}: #{inspect(body)}")
        {:error, {:unexpected_response, status}}

      {:error, %{reason: :timeout}} ->
        Logger.error("MedSchedule timeout for patient #{patient.id}")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("MedSchedule error for patient #{patient.id}: #{inspect(reason)}")
        {:error, {:scheduler_error, reason}}
    end
  end
  # VALIDATION: SMELL END

  def cancel(appointment_id, reason \\ "patient_request") do
    with {:ok, appt} <- Repo.get(Appointment, appointment_id) |> then(&if(&1, do: {:ok, &1}, else: {:error, :not_found})),
         {:ok, _} <- Client.cancel(appt.external_id, reason) do
      Appointment.changeset(appt, %{status: :cancelled, cancellation_reason: reason})
      |> Repo.update()
    end
  end
end
```
