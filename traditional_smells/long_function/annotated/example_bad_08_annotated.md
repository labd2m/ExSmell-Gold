# Annotated Example — Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Scheduling.AppointmentBooker.book/3`
- **Affected function(s):** `book/3`
- **Short explanation:** The `book/3` function blends slot availability checking, conflict detection, attendee validation, calendar entry creation, confirmation notifications, and reminder scheduling all inside a single function. The many interleaved steps make the function too long and multi-purpose.

---

```elixir
defmodule Scheduling.AppointmentBooker do
  @moduledoc """
  Handles booking of appointments within a service provider's availability windows,
  including conflict detection and confirmation dispatch.
  """

  alias Scheduling.{Appointment, AvailabilitySlot, Attendee, ReminderJob, Repo}
  alias Notifications.Dispatcher
  require Logger

  @booking_buffer_minutes 15
  @reminder_hours_before [24, 1]

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `book/3` handles slot loading, overlap checks,
  # VALIDATION: duration validation, attendee upsert, appointment insertion,
  # VALIDATION: slot marking, confirmation notification, and reminder job scheduling
  # VALIDATION: all in one function that spans well over ten lines.
  def book(provider_id, requester_id, %{start_at: start_at, end_at: end_at, service: service} = params) do
    Logger.info("Booking appointment provider=#{provider_id} requester=#{requester_id}")

    # --- Validate duration ---
    duration_minutes = DateTime.diff(end_at, start_at, :second) |> div(60)

    cond do
      duration_minutes < 10 ->
        {:error, :duration_too_short}

      duration_minutes > 480 ->
        {:error, :duration_too_long}

      true ->
        # --- Check provider availability ---
        buffered_start = DateTime.add(start_at, -@booking_buffer_minutes * 60, :second)
        buffered_end   = DateTime.add(end_at, @booking_buffer_minutes * 60, :second)

        overlapping_slots =
          AvailabilitySlot
          |> AvailabilitySlot.for_provider(provider_id)
          |> AvailabilitySlot.overlapping(buffered_start, buffered_end)
          |> Repo.all()

        available_slot =
          Enum.find(overlapping_slots, fn slot ->
            DateTime.compare(slot.starts_at, start_at) != :gt and
              DateTime.compare(slot.ends_at, end_at) != :lt and
              slot.status == :open
          end)

        if is_nil(available_slot) do
          {:error, :slot_not_available}
        else
          # --- Check for conflicting appointments ---
          existing_conflicts =
            Appointment
            |> Appointment.for_provider(provider_id)
            |> Appointment.overlapping(start_at, end_at)
            |> Appointment.active()
            |> Repo.all()

          if existing_conflicts != [] do
            {:error, :conflict_with_existing_appointment}
          else
            # --- Upsert attendee ---
            attendee =
              case Repo.get_by(Attendee, user_id: requester_id) do
                nil ->
                  Repo.insert!(%Attendee{user_id: requester_id, provider_id: provider_id})

                existing ->
                  existing
              end

            # --- Create appointment ---
            appt_attrs = %{
              provider_id: provider_id,
              attendee_id: attendee.id,
              availability_slot_id: available_slot.id,
              service: service,
              start_at: start_at,
              end_at: end_at,
              duration_minutes: duration_minutes,
              status: :confirmed,
              notes: Map.get(params, :notes),
              booked_at: DateTime.utc_now()
            }

            case Repo.insert(Appointment.changeset(%Appointment{}, appt_attrs)) do
              {:ok, appointment} ->
                # --- Mark slot as booked ---
                available_slot
                |> AvailabilitySlot.changeset(%{status: :booked})
                |> Repo.update!()

                # --- Send confirmation ---
                Dispatcher.dispatch(requester_id, %{
                  type: "appointment_confirmed",
                  payload: %{
                    appointment_id: appointment.id,
                    provider_id: provider_id,
                    start_at: start_at,
                    service: service
                  }
                })

                # --- Schedule reminders ---
                Enum.each(@reminder_hours_before, fn hours ->
                  remind_at = DateTime.add(start_at, -hours * 3600, :second)

                  if DateTime.compare(remind_at, DateTime.utc_now()) == :gt do
                    Repo.insert!(%ReminderJob{
                      appointment_id: appointment.id,
                      user_id: requester_id,
                      remind_at: remind_at,
                      status: :pending
                    })
                  end
                end)

                Logger.info("Appointment #{appointment.id} booked successfully")
                {:ok, appointment}

              {:error, changeset} ->
                Logger.error("Failed to insert appointment: #{inspect(changeset.errors)}")
                {:error, changeset}
            end
          end
        end
    end
  end
  # VALIDATION: SMELL END

  def cancel(appointment_id, reason \\ :user_requested) do
    with %Appointment{} = appt <- Repo.get(Appointment, appointment_id),
         {:ok, _} <- appt |> Appointment.changeset(%{status: :cancelled, cancel_reason: reason}) |> Repo.update() do
      :ok
    else
      nil -> {:error, :not_found}
      err -> err
    end
  end
end
```
