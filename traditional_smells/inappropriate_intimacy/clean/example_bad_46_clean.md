```elixir
defmodule Scheduling.AppointmentManager do
  @moduledoc """
  Books, reschedules, and cancels patient appointments with healthcare providers.
  Validates availability against provider calendars before confirming bookings.
  """

  require Logger

  alias Scheduling.{Provider, Calendar, Appointment, SlotIndex}
  alias Accounts.Patient
  alias Repo

  @booking_horizon_days 60
  @cancellation_cutoff_hours 24

  def book(patient_id, provider_id, preferences) do
    with {:ok, patient} <- Patient.fetch(patient_id),
         {:ok, provider} <- Provider.fetch(provider_id),
         {:ok, calendar} <- Calendar.for_provider(provider_id) do
      attempt_booking(patient, provider, calendar, preferences)
    end
  end

  defp attempt_booking(patient, provider, calendar, preferences) do
    cond do
      not provider.accepting_new_patients and not existing_patient?(patient.id, provider.id) ->
        {:error, :not_accepting_new_patients}

      preferences[:specialty] not in provider.specialties ->
        {:error, :specialty_not_offered}

      true ->
        requested_date = preferences[:preferred_date] || Date.utc_today()

        case find_available_slot(calendar, provider, requested_date) do
          {:ok, slot} ->
            confirm_booking(patient, provider, slot, preferences)

          {:error, :no_slots} ->
            {:error, :no_available_slots}
        end
    end
  end

  defp find_available_slot(calendar, provider, from_date) do
    horizon = Date.add(from_date, @booking_horizon_days)

    from_date
    |> Date.range(horizon)
    |> Enum.reject(fn date ->
      Date.day_of_week(date) in [6, 7] or date in calendar.blocked_dates
    end)
    |> Enum.find_value(fn date ->
      {open_hour, close_hour} = calendar.working_hours
      duration = calendar.slot_duration_minutes

      slots =
        for start_min <- 0..((close_hour - open_hour) * 60 - duration)//duration do
          total_min = open_hour * 60 + start_min

          %{
            date: date,
            start_time: Time.from_erl!({div(total_min, 60), rem(total_min, 60), 0}),
            duration_minutes: duration
          }
        end

      booked_count = Appointment.count_for_date(provider.id, date)

      if booked_count >= provider.max_daily_appointments do
        nil
      else
        Enum.find(slots, fn slot ->
          not SlotIndex.taken?(provider.id, slot.date, slot.start_time)
        end)
      end
    end)
    |> case do
      nil -> {:error, :no_slots}
      slot -> {:ok, slot}
    end
  end

  defp confirm_booking(patient, provider, slot, preferences) do
    appt = %Appointment{
      patient_id: patient.id,
      provider_id: provider.id,
      date: slot.date,
      start_time: slot.start_time,
      duration_minutes: slot.duration_minutes,
      specialty: preferences[:specialty],
      notes: preferences[:notes],
      status: :confirmed,
      booked_at: DateTime.utc_now()
    }

    Repo.transaction(fn ->
      {:ok, saved} = Repo.insert(appt)
      SlotIndex.mark_taken(provider.id, slot.date, slot.start_time)
      saved
    end)
    |> case do
      {:ok, saved} ->
        Logger.info("Appointment #{saved.id} booked for patient #{patient.id}")
        {:ok, saved}

      {:error, reason} ->
        Logger.error("Booking transaction failed: #{inspect(reason)}")
        {:error, :booking_failed}
    end
  end

  def cancel(%Appointment{status: :confirmed} = appt) do
    hours_until = hours_until_appointment(appt.date, appt.start_time)

    if hours_until < @cancellation_cutoff_hours do
      {:error, :cancellation_window_passed}
    else
      Repo.transaction(fn ->
        {:ok, updated} =
          appt
          |> Appointment.changeset(%{status: :cancelled, cancelled_at: DateTime.utc_now()})
          |> Repo.update()

        SlotIndex.mark_free(appt.provider_id, appt.date, appt.start_time)
        updated
      end)
    end
  end

  def cancel(%Appointment{}), do: {:error, :not_cancellable}

  defp existing_patient?(patient_id, provider_id) do
    Appointment.exists_for_pair?(patient_id, provider_id)
  end

  defp hours_until_appointment(date, start_time) do
    appt_dt = DateTime.new!(date, start_time, "UTC")
    DateTime.diff(appt_dt, DateTime.utc_now(), :hour)
  end
end
```
