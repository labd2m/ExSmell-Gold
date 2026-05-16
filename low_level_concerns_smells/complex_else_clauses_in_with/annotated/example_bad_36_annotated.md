# Annotated Example 36 — Complex else clauses in with

## Metadata

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `book_appointment/3`, inside the `with` expression's `else` block
- **Affected function(s):** `book_appointment/3`
- **Short explanation:** Five pipeline steps each return distinct failure shapes. Concentrating all failure handling in one `else` block makes it unclear which step produced a given error without tracing backwards through every clause.

---

```elixir
defmodule Scheduling.AppointmentBooker do
  @moduledoc """
  Orchestrates appointment booking: provider resolution, availability
  check, conflict detection, slot reservation, and confirmation dispatch.
  """

  alias Scheduling.{
    ProviderRepo,
    AvailabilityEngine,
    ConflictChecker,
    SlotRegistry,
    ConfirmationMailer
  }

  require Logger

  @doc """
  Books an appointment for `patient_id` with `provider_id` at `slot`.

  `slot` is a `%{date: Date.t(), time: Time.t(), duration_minutes: pos_integer()}`.

  Returns `{:ok, appointment}` or a descriptive error.
  """
  @spec book_appointment(String.t(), String.t(), map()) ::
          {:ok, map()}
          | {:error, :provider_not_found}
          | {:error, :slot_unavailable}
          | {:error, :patient_conflict}
          | {:error, :reservation_failed}
          | {:error, :confirmation_failed}
  def book_appointment(patient_id, provider_id, slot) do
    # VALIDATION: SMELL START - Complex else clauses in with
    # VALIDATION: This is a smell because five with-clauses fail with five
    # different shapes ({:error, :not_found}, {:error, :unavailable, _},
    # {:conflict, _}, {:error, :reserve, _}, {:error, :mail}).
    # All are merged into one else block, removing any structural indication
    # of which step is responsible for a given failure pattern.
    with {:ok, provider}     <- ProviderRepo.fetch(provider_id),
         {:ok, availability} <- AvailabilityEngine.check(provider, slot),
         :ok                 <- ConflictChecker.check_patient(patient_id, slot),
         {:ok, reservation}  <- SlotRegistry.reserve(availability.slot_id, patient_id),
         {:ok, confirmation} <- ConfirmationMailer.send(patient_id, provider, reservation) do
      appointment = %{
        id:              reservation.id,
        patient_id:      patient_id,
        provider_id:     provider_id,
        date:            slot.date,
        time:            slot.time,
        duration:        slot.duration_minutes,
        confirmation_no: confirmation.number,
        status:          :confirmed,
        booked_at:       DateTime.utc_now()
      }

      Logger.info("Appointment #{appointment.id} booked for patient #{patient_id}")
      {:ok, appointment}
    else
      {:error, :not_found} ->
        Logger.warn("Provider #{provider_id} not found")
        {:error, :provider_not_found}

      {:error, :unavailable, reason} ->
        Logger.info("Slot unavailable for provider #{provider_id}: #{reason}")
        {:error, :slot_unavailable}

      {:conflict, conflicting_slot} ->
        Logger.info("Patient #{patient_id} has conflict with #{inspect(conflicting_slot)}")
        {:error, :patient_conflict}

      {:error, :reserve, detail} ->
        Logger.error("Slot reservation failed: #{inspect(detail)}")
        {:error, :reservation_failed}

      {:error, :mail} ->
        Logger.error("Confirmation email failed for appointment")
        {:error, :confirmation_failed}
    end
    # VALIDATION: SMELL END
  end
end
```
