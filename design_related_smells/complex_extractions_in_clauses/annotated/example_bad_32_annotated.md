## Metadata

- **Smell name**: Complex extractions in clauses
- **Expected smell location**: `book_appointment/1`, all three clauses
- **Affected function(s)**: `book_appointment/1`
- **Short explanation**: Each clause of `book_appointment/1` extracts `patient_id`, `provider_id`, `requested_at`, `notes`, and `location` from `%AppointmentRequest{}` for body-only use. Guards depend only on `appointment_type` and `insurance_tier`. The full repeated extraction across all three clauses makes it unnecessarily hard to discern that only two of the seven fields are relevant to clause selection.

```elixir
defmodule Scheduling.AppointmentBooker do
  alias Scheduling.{
    AppointmentRequest,
    Provider,
    Calendar,
    InsuranceCoverage,
    ConfirmationMailer,
    ReminderQueue
  }

  require Logger

  @moduledoc """
  Handles appointment booking across different appointment types
  and insurance coverage tiers.
  """

  @reminder_hours_before 24

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `patient_id`, `provider_id`, `requested_at`, `notes`,
  # VALIDATION: and `location` are extracted in every clause head for use only in the body.
  # VALIDATION: Only `appointment_type` and `insurance_tier` are referenced in guards.
  # VALIDATION: The seven-field destructuring in each of three clauses hides the two fields
  # VALIDATION: that actually differentiate the clauses.
  def book_appointment(%AppointmentRequest{
        id: request_id,
        patient_id: patient_id,
        provider_id: provider_id,
        appointment_type: appointment_type,
        insurance_tier: insurance_tier,
        requested_at: requested_at,
        notes: notes,
        location: location
      })
      when appointment_type == :consultation and insurance_tier in [:gold, :platinum] do
    Logger.info("Booking covered consultation for patient #{patient_id}")
    provider = Provider.get!(provider_id)
    copay = InsuranceCoverage.copay(:consultation, insurance_tier)

    with {:ok, slot} <- Calendar.reserve_slot(provider_id, requested_at, 30) do
      appt = %{
        request_id: request_id,
        patient_id: patient_id,
        provider: provider.name,
        provider_id: provider_id,
        slot: slot,
        location: location,
        copay_cents: copay,
        notes: notes,
        type: :consultation
      }

      ConfirmationMailer.send(patient_id, appt)
      ReminderQueue.schedule(patient_id, slot, @reminder_hours_before)
      {:ok, appt}
    end
  end

  def book_appointment(%AppointmentRequest{
        id: request_id,
        patient_id: patient_id,
        provider_id: provider_id,
        appointment_type: appointment_type,
        insurance_tier: insurance_tier,
        requested_at: requested_at,
        notes: notes,
        location: location
      })
      when appointment_type == :follow_up and insurance_tier != :none do
    Logger.info("Booking covered follow-up for patient #{patient_id}")
    provider = Provider.get!(provider_id)
    copay = InsuranceCoverage.copay(:follow_up, insurance_tier)

    with {:ok, slot} <- Calendar.reserve_slot(provider_id, requested_at, 15) do
      appt = %{
        request_id: request_id,
        patient_id: patient_id,
        provider: provider.name,
        provider_id: provider_id,
        slot: slot,
        location: location,
        copay_cents: copay,
        notes: notes,
        type: :follow_up
      }

      ConfirmationMailer.send(patient_id, appt)
      ReminderQueue.schedule(patient_id, slot, @reminder_hours_before)
      {:ok, appt}
    end
  end

  def book_appointment(%AppointmentRequest{
        id: request_id,
        patient_id: patient_id,
        provider_id: provider_id,
        appointment_type: appointment_type,
        insurance_tier: insurance_tier,
        requested_at: requested_at,
        notes: notes,
        location: location
      })
      when appointment_type in [:consultation, :follow_up, :specialist] and insurance_tier == :none do
    Logger.info("Booking self-pay appointment for patient #{patient_id}")
    provider = Provider.get!(provider_id)
    rate = Provider.self_pay_rate(provider, appointment_type)

    with {:ok, slot} <- Calendar.reserve_slot(provider_id, requested_at, 45) do
      appt = %{
        request_id: request_id,
        patient_id: patient_id,
        provider: provider.name,
        provider_id: provider_id,
        slot: slot,
        location: location,
        self_pay_rate_cents: rate,
        notes: notes,
        type: appointment_type
      }

      ConfirmationMailer.send_self_pay(patient_id, appt)
      ReminderQueue.schedule(patient_id, slot, @reminder_hours_before)
      {:ok, appt}
    end
  end
  # VALIDATION: SMELL END
end
```
