# Annotated Example 31

- **Smell name:** Comments
- **Expected smell location:** `AppointmentScheduler.book_appointment/3`
- **Affected function(s):** `book_appointment/3`
- **Short explanation:** The developer used `#` comment lines to describe the function's behaviour and return values instead of `@doc`. Elixir's documentation system only recognises `@doc` attributes, so this documentation is effectively invisible to any tooling.

```elixir
defmodule MyApp.AppointmentScheduler do
  @moduledoc """
  Manages appointment scheduling, availability checks, and calendar
  integration for the MyApp healthcare booking platform.
  """

  alias MyApp.Repo
  alias MyApp.Scheduling.{Appointment, Provider, TimeSlot}
  alias Ecto.Multi

  require Logger

  @min_advance_hours 1
  @max_advance_days 90

  @doc """
  Lists available time slots for a given provider and date range.

  Returns a list of `%TimeSlot{}` structs that are not yet booked.
  """
  def available_slots(provider_id, date_from, date_to) do
    TimeSlot
    |> TimeSlot.for_provider(provider_id)
    |> TimeSlot.between(date_from, date_to)
    |> TimeSlot.available()
    |> Repo.all()
  end

  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because `book_appointment/3` is documented with `#` comment
  # VALIDATION: blocks rather than `@doc`, so ExDoc cannot render it and `h/1` in IEx will
  # VALIDATION: show no documentation.

  # book_appointment/3
  #
  # Books an appointment for `patient_id` with `provider_id` at `slot_id`.
  #
  # Validations performed:
  #   - The slot must belong to the given provider.
  #   - The slot must be available (not already booked or blocked).
  #   - The slot start time must be at least @min_advance_hours from now.
  #   - The slot start time must be no more than @max_advance_days from today.
  #   - The patient must not already have an overlapping appointment.
  #
  # On success, the slot is marked as booked and an Appointment record is created.
  #
  # Returns:
  #   {:ok, %Appointment{}} on success
  #   {:error, :slot_unavailable}
  #   {:error, :outside_booking_window}
  #   {:error, :overlapping_appointment}
  #   {:error, :provider_mismatch}
  def book_appointment(patient_id, provider_id, slot_id) do
    # VALIDATION: SMELL END
    with {:ok, slot} <- fetch_and_validate_slot(slot_id, provider_id),
         :ok <- validate_booking_window(slot.starts_at),
         :ok <- check_patient_availability(patient_id, slot) do
      Multi.new()
      |> Multi.update(:slot, TimeSlot.changeset(slot, %{status: :booked}))
      |> Multi.insert(:appointment, build_appointment(patient_id, provider_id, slot))
      |> Repo.transaction()
      |> case do
        {:ok, %{appointment: appt}} -> {:ok, appt}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  @doc """
  Cancels an existing appointment and releases the associated time slot.

  Returns `{:ok, appointment}` or `{:error, reason}`.
  """
  def cancel_appointment(appointment_id, cancelled_by) do
    case Repo.get(Appointment, appointment_id) do
      nil ->
        {:error, :not_found}

      %Appointment{status: :cancelled} ->
        {:error, :already_cancelled}

      appointment ->
        Multi.new()
        |> Multi.update(
          :appointment,
          Appointment.changeset(appointment, %{
            status: :cancelled,
            cancelled_by: cancelled_by,
            cancelled_at: DateTime.utc_now()
          })
        )
        |> Multi.update(:slot, release_slot(appointment.slot_id))
        |> Repo.transaction()
        |> case do
          {:ok, %{appointment: a}} ->
            Logger.info("Appointment #{appointment_id} cancelled by #{cancelled_by}")
            {:ok, a}

          {:error, _step, reason, _changes} ->
            {:error, reason}
        end
    end
  end

  # --- Private helpers ---

  defp fetch_and_validate_slot(slot_id, provider_id) do
    case Repo.get(TimeSlot, slot_id) do
      nil -> {:error, :slot_not_found}
      %TimeSlot{provider_id: ^provider_id, status: :available} = slot -> {:ok, slot}
      %TimeSlot{provider_id: pid} when pid != provider_id -> {:error, :provider_mismatch}
      %TimeSlot{} -> {:error, :slot_unavailable}
    end
  end

  defp validate_booking_window(starts_at) do
    now = DateTime.utc_now()
    min_start = DateTime.add(now, @min_advance_hours * 3600, :second)
    max_start = DateTime.add(now, @max_advance_days * 86_400, :second)

    cond do
      DateTime.before?(starts_at, min_start) -> {:error, :outside_booking_window}
      DateTime.after?(starts_at, max_start) -> {:error, :outside_booking_window}
      true -> :ok
    end
  end

  defp check_patient_availability(patient_id, slot) do
    overlap =
      Appointment
      |> Appointment.for_patient(patient_id)
      |> Appointment.overlapping(slot.starts_at, slot.ends_at)
      |> Repo.exists?()

    if overlap, do: {:error, :overlapping_appointment}, else: :ok
  end

  defp build_appointment(patient_id, provider_id, slot) do
    Appointment.changeset(%Appointment{}, %{
      patient_id: patient_id,
      provider_id: provider_id,
      slot_id: slot.id,
      starts_at: slot.starts_at,
      ends_at: slot.ends_at,
      status: :confirmed
    })
  end

  defp release_slot(slot_id) do
    slot = Repo.get!(TimeSlot, slot_id)
    TimeSlot.changeset(slot, %{status: :available})
  end
end
```
