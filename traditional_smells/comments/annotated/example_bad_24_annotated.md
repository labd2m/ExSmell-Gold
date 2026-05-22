# Annotated Example — Code Smell: Comments

| Field | Value |
|---|---|
| **Smell name** | Comments |
| **Expected smell location** | `AppointmentScheduler.book_slot/3` |
| **Affected function(s)** | `book_slot/3` |
| **Short explanation** | `book_slot/3` uses a multi-line `#` comment block for its description instead of an `@doc` attribute, meaning no documentation tooling can discover or render it. |

```elixir
defmodule MyApp.AppointmentScheduler do
  @moduledoc """
  Handles appointment booking, cancellation, and availability checks
  for the MyApp clinic scheduling system.
  """

  import Ecto.Query
  alias MyApp.{Repo, Appointment, Provider, TimeSlot, Patient}
  require Logger

  @min_booking_notice_hours 2
  @max_future_booking_days 90
  @cancellation_window_hours 24

  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because `book_slot/3` documentation consists entirely
  # VALIDATION: of plain `#` comment lines placed above the function. No `@doc` is used,
  # VALIDATION: so neither ExDoc nor IEx `h/1` can surface this information to developers.

  # book_slot/3
  #
  # Books an available time slot for a patient with a given provider.
  #
  # Parameters:
  #   patient_id  - integer, ID of the patient making the booking
  #   slot_id     - integer, ID of the TimeSlot to reserve
  #   notes       - string (optional), clinical notes to attach to the appointment
  #
  # Validations performed:
  #   - The slot must exist and be in :available status.
  #   - The slot start time must be at least @min_booking_notice_hours from now.
  #   - The slot must not be more than @max_future_booking_days in the future.
  #   - The patient must not have another appointment with the same provider
  #     on the same calendar day.
  #
  # On success, the slot status is set to :booked and an Appointment record
  # is created. Returns {:ok, appointment} or {:error, reason}.

  # VALIDATION: SMELL END
  def book_slot(patient_id, slot_id, notes \\ nil) do
    Repo.transaction(fn ->
      with {:ok, slot} <- fetch_available_slot(slot_id),
           :ok <- validate_booking_window(slot),
           {:ok, patient} <- fetch_patient(patient_id),
           :ok <- check_day_conflict(patient_id, slot) do
        {:ok, appointment} =
          %Appointment{}
          |> Appointment.changeset(%{
            patient_id: patient.id,
            provider_id: slot.provider_id,
            time_slot_id: slot.id,
            start_time: slot.start_time,
            end_time: slot.end_time,
            notes: notes,
            status: :scheduled
          })
          |> Repo.insert()

        slot
        |> TimeSlot.changeset(%{status: :booked})
        |> Repo.update!()

        Logger.info("[Scheduler] Patient #{patient_id} booked slot #{slot_id}")
        appointment
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, appointment} -> {:ok, appointment}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Cancels an existing appointment.

  If the cancellation is made within `@cancellation_window_hours` of the
  appointment start, a late-cancellation flag is recorded. The associated
  time slot is returned to `:available` status.

  Returns `{:ok, appointment}` or `{:error, :appointment_not_found}`.
  """
  def cancel_appointment(appointment_id, reason \\ nil) do
    Repo.transaction(fn ->
      case Repo.get(Appointment, appointment_id) do
        nil ->
          Repo.rollback(:appointment_not_found)

        appointment ->
          late_cancel = is_late_cancellation?(appointment)

          appointment
          |> Appointment.changeset(%{
            status: :cancelled,
            cancellation_reason: reason,
            late_cancellation: late_cancel,
            cancelled_at: DateTime.utc_now()
          })
          |> Repo.update!()

          Repo.get!(TimeSlot, appointment.time_slot_id)
          |> TimeSlot.changeset(%{status: :available})
          |> Repo.update!()

          Logger.info("[Scheduler] Appointment #{appointment_id} cancelled")
          appointment
      end
    end)
  end

  @doc """
  Returns all available time slots for a given provider within a date range.
  """
  def available_slots(provider_id, %Date{} = from, %Date{} = to) do
    Repo.all(
      from(s in TimeSlot,
        where:
          s.provider_id == ^provider_id and
            s.status == :available and
            fragment("DATE(?)", s.start_time) >= ^from and
            fragment("DATE(?)", s.start_time) <= ^to,
        order_by: [asc: s.start_time]
      )
    )
  end

  ## Private

  defp fetch_available_slot(slot_id) do
    case Repo.get(TimeSlot, slot_id) do
      nil -> {:error, :slot_not_found}
      %TimeSlot{status: :available} = slot -> {:ok, slot}
      _ -> {:error, :slot_unavailable}
    end
  end

  defp validate_booking_window(%TimeSlot{start_time: start_time}) do
    now = DateTime.utc_now()
    min_start = DateTime.add(now, @min_booking_notice_hours * 3600, :second)
    max_start = DateTime.add(now, @max_future_booking_days * 86_400, :second)

    cond do
      DateTime.compare(start_time, min_start) == :lt ->
        {:error, :too_soon}
      DateTime.compare(start_time, max_start) == :gt ->
        {:error, :too_far_future}
      true ->
        :ok
    end
  end

  defp fetch_patient(patient_id) do
    case Repo.get(Patient, patient_id) do
      nil -> {:error, :patient_not_found}
      patient -> {:ok, patient}
    end
  end

  defp check_day_conflict(patient_id, slot) do
    date = DateTime.to_date(slot.start_time)

    conflict =
      Repo.one(
        from(a in Appointment,
          where:
            a.patient_id == ^patient_id and
              a.provider_id == ^slot.provider_id and
              a.status == :scheduled and
              fragment("DATE(?)", a.start_time) == ^date
        )
      )

    if conflict, do: {:error, :day_conflict}, else: :ok
  end

  defp is_late_cancellation?(%Appointment{start_time: start_time}) do
    cutoff = DateTime.add(DateTime.utc_now(), @cancellation_window_hours * 3600, :second)
    DateTime.compare(start_time, cutoff) == :lt
  end
end
```
