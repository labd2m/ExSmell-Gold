# Annotated Example 27

## Metadata

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Healthcare.AppointmentReminder.schedule/2`, lines where `patient` map keys are accessed dynamically
- **Affected function(s):** `schedule/2`
- **Short explanation:** `patient[:contact_email]`, `patient[:contact_phone]`, `patient[:preferred_channel]`, and `patient[:opt_out]` use dynamic bracket access on a plain map. When `:opt_out` is absent, `nil` is treated as falsy and reminder messages are sent to patients who may have opted out, violating communication preferences. A missing `:preferred_channel` silently falls through channel selection logic without indicating a data integrity problem.

---

```elixir
defmodule Healthcare.AppointmentReminder do
  @moduledoc """
  Schedules and dispatches pre-appointment reminders to patients via
  their preferred communication channel (email, SMS, or voice call).
  Respects opt-out preferences and configurable lead times.
  """

  require Logger

  @valid_channels      [:email, :sms, :voice]
  @default_channel     :email
  @reminder_offsets_h  [48, 24, 2]

  @type reminder_job :: %{
          id: String.t(),
          patient_id: String.t(),
          appointment_id: String.t(),
          channel: atom(),
          contact: String.t(),
          scheduled_at: DateTime.t(),
          message: String.t(),
          status: :pending | :sent | :failed
        }

  @spec schedule(map(), map()) ::
          {:ok, list(reminder_job())} | {:error, String.t()}
  def schedule(patient, appointment) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `patient[:contact_email]`,
    # `patient[:contact_phone]`, `patient[:preferred_channel]`, and
    # `patient[:opt_out]` use dynamic bracket access on a plain map.
    # When `:opt_out` is absent, `nil` is returned and treated as falsy by
    # the guard, so reminders are dispatched to patients who may have opted
    # out, violating consent requirements. When `:preferred_channel` is
    # absent, `nil` flows into `resolve_channel/3` and silently falls back to
    # the default instead of surfacing a missing patient preference.
    contact_email     = patient[:contact_email]
    contact_phone     = patient[:contact_phone]
    preferred_channel = patient[:preferred_channel]
    opt_out           = patient[:opt_out]
    # VALIDATION: SMELL END

    if opt_out do
      Logger.info("Reminders suppressed due to opt-out",
        patient_id: patient.id,
        appointment_id: appointment.id
      )

      {:ok, []}
    else
      channel = resolve_channel(preferred_channel, contact_email, contact_phone)
      contact = resolve_contact(channel, contact_email, contact_phone)

      with :ok <- validate_contact(channel, contact) do
        jobs =
          @reminder_offsets_h
          |> Enum.map(fn offset_h ->
            scheduled_at =
              appointment.start_time
              |> DateTime.add(-offset_h * 3600, :second)

            %{
              id: generate_id(),
              patient_id: patient.id,
              appointment_id: appointment.id,
              channel: channel,
              contact: contact,
              scheduled_at: scheduled_at,
              message: build_message(patient, appointment, offset_h),
              status: :pending
            }
          end)
          |> Enum.filter(fn job ->
            DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
          end)

        Logger.info("Reminders scheduled",
          patient_id: patient.id,
          appointment_id: appointment.id,
          channel: channel,
          job_count: length(jobs)
        )

        {:ok, jobs}
      end
    end
  end

  @spec cancel_reminders(String.t(), list(reminder_job())) :: :ok
  def cancel_reminders(appointment_id, jobs) do
    cancelled =
      jobs
      |> Enum.filter(&(&1.appointment_id == appointment_id && &1.status == :pending))
      |> length()

    Logger.info("Reminders cancelled",
      appointment_id: appointment_id,
      cancelled_count: cancelled
    )

    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp resolve_channel(preferred, email, phone) do
    cond do
      preferred in @valid_channels           -> preferred
      is_binary(phone) && phone != ""        -> :sms
      is_binary(email) && email != ""        -> :email
      true                                   -> @default_channel
    end
  end

  defp resolve_contact(:email, email, _phone), do: email
  defp resolve_contact(:sms, _email, phone),   do: phone
  defp resolve_contact(:voice, _email, phone), do: phone
  defp resolve_contact(_, email, _),            do: email

  defp validate_contact(:email, nil),
    do: {:error, "No email address available for patient"}

  defp validate_contact(:sms, nil),
    do: {:error, "No phone number available for SMS reminder"}

  defp validate_contact(:voice, nil),
    do: {:error, "No phone number available for voice reminder"}

  defp validate_contact(_, _), do: :ok

  defp build_message(patient, appointment, offset_h) do
    name = Map.get(patient, :full_name, "Patient")
    time = Calendar.strftime(appointment.start_time, "%d/%m/%Y at %H:%M")
    "Dear #{name}, this is a reminder of your appointment on #{time} " <>
      "(in approximately #{offset_h} hour(s)). Please arrive 10 minutes early."
  end

  defp generate_id do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end
end
```
