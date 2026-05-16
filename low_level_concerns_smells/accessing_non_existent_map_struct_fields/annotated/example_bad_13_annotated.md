# Annotated Example 13

## Metadata

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Scheduling.AppointmentBooker.book/3`, lines where `preferences` map keys are accessed dynamically
- **Affected function(s):** `book/3`
- **Short explanation:** `preferences[:preferred_staff_id]`, `preferences[:room_type]`, and `preferences[:reminder_minutes]` are read via dynamic bracket access from an unvalidated plain map. If `:reminder_minutes` is absent, `nil` flows into `DateTime.add(slot.start_time, nil, :minute)`, crashing at runtime. If `:room_type` is absent, the room-selection logic silently falls back to a default without indicating a configuration issue.

---

```elixir
defmodule Scheduling.AppointmentBooker do
  @moduledoc """
  Books appointments into available calendar slots, optionally
  honouring staff preferences, room type requirements, and
  pre-appointment reminder scheduling.
  """

  require Logger

  @default_reminder_minutes 30

  @type slot :: %{
          id: String.t(),
          start_time: DateTime.t(),
          end_time: DateTime.t(),
          staff_id: String.t(),
          room_id: String.t(),
          room_type: String.t(),
          available: boolean()
        }

  @type appointment :: %{
          id: String.t(),
          slot_id: String.t(),
          patient_id: String.t(),
          staff_id: String.t(),
          room_id: String.t(),
          reminder_at: DateTime.t(),
          notes: String.t() | nil,
          status: atom()
        }

  @spec book(list(slot()), map(), map()) :: {:ok, appointment()} | {:error, String.t()}
  def book(available_slots, patient, preferences) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `preferences[:preferred_staff_id]`,
    # `preferences[:room_type]`, and `preferences[:reminder_minutes]` use
    # dynamic bracket access on a plain map. When `:reminder_minutes` is
    # absent, `nil` is returned and `DateTime.add(slot.start_time, nil,
    # :minute)` raises a `FunctionClauseError` at runtime. When
    # `:preferred_staff_id` is absent, `nil` is compared against
    # `slot.staff_id` in `Enum.find/2`, silently skipping staff preference
    # filtering rather than raising a clear configuration error.
    preferred_staff_id = preferences[:preferred_staff_id]
    room_type          = preferences[:room_type]
    reminder_minutes   = preferences[:reminder_minutes]
    # VALIDATION: SMELL END

    with {:ok, slot}        <- find_slot(available_slots, preferred_staff_id, room_type),
         {:ok, reminder_at} <- build_reminder_time(slot, reminder_minutes),
         {:ok, appointment} <- persist_appointment(slot, patient, reminder_at, preferences) do
      Logger.info("Appointment booked",
        appointment_id: appointment.id,
        patient_id: patient.id,
        slot_id: slot.id,
        reminder_at: reminder_at
      )

      {:ok, appointment}
    end
  end

  @spec cancel(String.t(), String.t()) :: :ok | {:error, String.t()}
  def cancel(appointment_id, reason) when is_binary(reason) do
    Logger.info("Appointment cancelled",
      appointment_id: appointment_id,
      reason: reason
    )

    :ok
  end

  @spec reschedule(appointment(), list(slot()), map()) ::
          {:ok, appointment()} | {:error, String.t()}
  def reschedule(%{} = existing, available_slots, preferences) do
    :ok = cancel(existing.id, "rescheduled")
    book(available_slots, %{id: existing.patient_id}, preferences)
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec find_slot(list(slot()), String.t() | nil, String.t() | nil) ::
          {:ok, slot()} | {:error, String.t()}
  defp find_slot(slots, preferred_staff_id, room_type) do
    available = Enum.filter(slots, & &1.available)

    result =
      cond do
        preferred_staff_id && room_type ->
          Enum.find(available, fn s ->
            s.staff_id == preferred_staff_id && s.room_type == room_type
          end)

        preferred_staff_id ->
          Enum.find(available, fn s -> s.staff_id == preferred_staff_id end)

        room_type ->
          Enum.find(available, fn s -> s.room_type == room_type end)

        true ->
          List.first(available)
      end

    case result do
      nil  -> {:error, "No available slot matches the given preferences"}
      slot -> {:ok, slot}
    end
  end

  @spec build_reminder_time(slot(), integer() | nil) ::
          {:ok, DateTime.t()} | {:error, String.t()}
  defp build_reminder_time(slot, reminder_minutes) do
    minutes = reminder_minutes || @default_reminder_minutes

    reminder_at = DateTime.add(slot.start_time, -minutes * 60, :second)

    if DateTime.compare(reminder_at, DateTime.utc_now()) == :gt do
      {:ok, reminder_at}
    else
      {:error, "Reminder time #{reminder_at} is in the past"}
    end
  end

  @spec persist_appointment(slot(), map(), DateTime.t(), map()) ::
          {:ok, appointment()} | {:error, String.t()}
  defp persist_appointment(slot, patient, reminder_at, preferences) do
    appointment = %{
      id: generate_id(),
      slot_id: slot.id,
      patient_id: patient.id,
      staff_id: slot.staff_id,
      room_id: slot.room_id,
      reminder_at: reminder_at,
      notes: Map.get(preferences, :notes),
      status: :confirmed
    }

    {:ok, appointment}
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end
end
```
