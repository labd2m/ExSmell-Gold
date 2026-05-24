# Annotated Example — Divergent Change

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** `AppointmentCenter` module (entire module)
- **Affected functions:** `book_appointment/3`, `reschedule_appointment/3`, `cancel_appointment/2`, `send_confirmation/1`, `send_reminder/1`, `bill_for_appointment/2`
- **Explanation:** `AppointmentCenter` handles scheduling/rescheduling/cancellation, client notifications (confirmation + reminders), and billing for completed appointments. Scheduling rules may change with provider availability logic, notification content/channels may change independently, and billing rates or insurance processing may change for entirely separate business reasons — making this module a Divergent Change.

---

```elixir
defmodule MyApp.AppointmentCenter do
  @moduledoc """
  Manages appointment booking, rescheduling, and cancellation; sends
  confirmations and reminders; and processes billing for completed visits.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.{Appointment, AppointmentBill}
  alias MyApp.Integrations.{Mailer, Twilio}
  import Ecto.Query

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because scheduling logic, client notification,
  # and appointment billing are three independent domains. New availability
  # rules affect scheduling, new communication channels affect notifications,
  # and insurance/billing policy changes affect the billing section — each
  # forcing unrelated modifications to this single module.

  ## ── Scheduling ───────────────────────────────────────────────────────────────

  @doc """
  Books a new appointment for a client with a given provider at a given slot.
  """
  def book_appointment(client_id, provider_id, %DateTime{} = slot) do
    if slot_available?(provider_id, slot) do
      %Appointment{}
      |> Appointment.changeset(%{
        client_id: client_id,
        provider_id: provider_id,
        scheduled_at: slot,
        duration_minutes: 60,
        status: :confirmed,
        booked_at: DateTime.utc_now()
      })
      |> Repo.insert()
      |> case do
        {:ok, appt} = result ->
          send_confirmation(appt)
          result

        error ->
          error
      end
    else
      {:error, :slot_unavailable}
    end
  end

  @doc """
  Reschedules an existing appointment to a new time slot.
  """
  def reschedule_appointment(%Appointment{} = appt, provider_id, %DateTime{} = new_slot) do
    if slot_available?(provider_id, new_slot) do
      appt
      |> Appointment.changeset(%{
        scheduled_at: new_slot,
        status: :confirmed,
        rescheduled_at: DateTime.utc_now()
      })
      |> Repo.update()
      |> case do
        {:ok, updated} = result ->
          send_confirmation(updated)
          result

        error ->
          error
      end
    else
      {:error, :slot_unavailable}
    end
  end

  @doc """
  Cancels an appointment and records the cancellation reason.
  """
  def cancel_appointment(%Appointment{status: :cancelled}, _reason) do
    {:error, :already_cancelled}
  end

  def cancel_appointment(%Appointment{} = appt, reason) do
    appt
    |> Appointment.changeset(%{
      status: :cancelled,
      cancellation_reason: reason,
      cancelled_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  defp slot_available?(provider_id, %DateTime{} = slot) do
    end_of_slot = DateTime.add(slot, 3600, :second)

    not Repo.exists?(
      from a in Appointment,
        where:
          a.provider_id == ^provider_id and
            a.status == :confirmed and
            a.scheduled_at < ^end_of_slot and
            a.scheduled_at >= ^slot
    )
  end

  ## ── Notifications ────────────────────────────────────────────────────────────

  @doc """
  Sends a booking confirmation by email and SMS to the client.
  """
  def send_confirmation(%Appointment{} = appt) do
    client = MyApp.Clients.get!(appt.client_id)
    formatted_time = Calendar.strftime(appt.scheduled_at, "%A %B %-d at %-I:%M %p")

    Mailer.send(%{
      to: client.email,
      subject: "Appointment Confirmed",
      text_body: "Your appointment is confirmed for #{formatted_time}."
    })

    if client.phone do
      Twilio.send_message(%{
        to: client.phone,
        body: "Confirmed: #{formatted_time}. Reply CANCEL to cancel."
      })
    end
  end

  @doc """
  Sends a reminder to the client 24 hours before the appointment.
  """
  def send_reminder(%Appointment{} = appt) do
    client = MyApp.Clients.get!(appt.client_id)
    formatted_time = Calendar.strftime(appt.scheduled_at, "%A at %-I:%M %p")

    Mailer.send(%{
      to: client.email,
      subject: "Reminder: Appointment Tomorrow",
      text_body: "Reminder: You have an appointment #{formatted_time}."
    })
  end

  ## ── Billing ──────────────────────────────────────────────────────────────────

  @doc """
  Creates a billing record for a completed appointment.
  Applies the provider's service rate and any applicable insurance offsets.
  """
  def bill_for_appointment(%Appointment{status: :completed} = appt, insurance_coverage_pct \\ 0) do
    provider = MyApp.Providers.get!(appt.provider_id)
    gross_cents = provider.hourly_rate_cents

    client_owes_cents =
      if insurance_coverage_pct > 0,
        do: round(gross_cents * (1 - insurance_coverage_pct / 100.0)),
        else: gross_cents

    %AppointmentBill{}
    |> AppointmentBill.changeset(%{
      appointment_id: appt.id,
      client_id: appt.client_id,
      gross_cents: gross_cents,
      insurance_coverage_pct: insurance_coverage_pct,
      client_owes_cents: client_owes_cents,
      status: :pending,
      billed_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  def bill_for_appointment(%Appointment{}, _), do: {:error, :appointment_not_completed}

  # VALIDATION: SMELL END
end
```
