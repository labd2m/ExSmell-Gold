```elixir
defmodule Scheduling.AppointmentManager do
  @moduledoc """
  Manages appointment bookings for a multi-provider scheduling system.
  Handles availability checks, booking creation, cancellations, and
  rescheduling with conflict detection.
  """

  require Logger

  alias Scheduling.Repo
  alias Scheduling.Schema.{Appointment, Provider, Patient}

  @appointment_duration_minutes 30
  @booking_lead_time_hours 2
  @max_daily_appointments 16


  @spec book_appointment(Provider.t(), Patient.t(), {integer(), integer()}) ::
          {:ok, Appointment.t()} | {:error, term()}
  def book_appointment(%Provider{} = provider, %Patient{} = patient, {start_hour, start_minute})
      when is_integer(start_hour) and is_integer(start_minute) do
    end_hour = div(start_minute + @appointment_duration_minutes, 60) + start_hour
    end_minute = rem(start_minute + @appointment_duration_minutes, 60)

    with :ok <- validate_slot_bounds(start_hour, start_minute),
         :ok <- check_availability(provider, start_hour, start_minute),
         :ok <- validate_lead_time(start_hour, start_minute),
         {:ok, appt} <-
           persist_appointment(provider, patient, start_hour, start_minute, end_hour, end_minute) do
      Logger.info(
        "Appointment booked: provider=#{provider.id} patient=#{patient.id} " <>
          "at #{pad(start_hour)}:#{pad(start_minute)}-#{pad(end_hour)}:#{pad(end_minute)}"
      )

      {:ok, appt}
    end
  end

  @spec check_availability(Provider.t(), integer(), integer()) ::
          :ok | {:error, :slot_unavailable}
  def check_availability(%Provider{} = provider, start_hour, start_minute)
      when is_integer(start_hour) and is_integer(start_minute) do
    end_minute_abs = start_hour * 60 + start_minute + @appointment_duration_minutes

    existing =
      Repo.all(
        from a in Appointment,
          where: a.provider_id == ^provider.id and a.date == ^Date.utc_today() and a.status != :cancelled
      )

    conflict =
      Enum.any?(existing, fn appt ->
        appt_start_abs = appt.start_hour * 60 + appt.start_minute
        appt_end_abs = appt.end_hour * 60 + appt.end_minute
        slot_start_abs = start_hour * 60 + start_minute

        slot_start_abs < appt_end_abs and end_minute_abs > appt_start_abs
      end)

    if conflict, do: {:error, :slot_unavailable}, else: :ok
  end

  @spec cancel_appointment(Appointment.t(), String.t()) ::
          {:ok, Appointment.t()} | {:error, term()}
  def cancel_appointment(%Appointment{} = appointment, reason) when is_binary(reason) do
    now_abs = DateTime.utc_now().hour * 60 + DateTime.utc_now().minute
    appt_abs = appointment.start_hour * 60 + appointment.start_minute

    if appointment.date == Date.utc_today() and appt_abs - now_abs < 60 do
      {:error, :cancellation_window_passed}
    else
      appointment
      |> Appointment.changeset(%{
        status: :cancelled,
        cancellation_reason: reason,
        cancelled_at: DateTime.utc_now()
      })
      |> Repo.update()
    end
  end

  @spec reschedule(Appointment.t(), integer(), integer()) ::
          {:ok, Appointment.t()} | {:error, term()}
  def reschedule(%Appointment{} = appointment, new_start_hour, new_start_minute)
      when is_integer(new_start_hour) and is_integer(new_start_minute) do
    new_end_hour = div(new_start_minute + @appointment_duration_minutes, 60) + new_start_hour
    new_end_minute = rem(new_start_minute + @appointment_duration_minutes, 60)

    provider = Repo.get!(Provider, appointment.provider_id)

    with :ok <- check_availability(provider, new_start_hour, new_start_minute) do
      appointment
      |> Appointment.changeset(%{
        start_hour: new_start_hour,
        start_minute: new_start_minute,
        end_hour: new_end_hour,
        end_minute: new_end_minute,
        rescheduled_at: DateTime.utc_now()
      })
      |> Repo.update()
    end
  end


  ## Private helpers

  defp validate_slot_bounds(hour, minute) when hour < 8 or hour > 17,
    do: {:error, {:out_of_office_hours, hour, minute}}

  defp validate_slot_bounds(_hour, minute) when minute not in [0, 30],
    do: {:error, {:invalid_minute_slot, minute}}

  defp validate_slot_bounds(_hour, _minute), do: :ok

  defp validate_lead_time(start_hour, start_minute) do
    now = DateTime.utc_now()
    slot_today_abs = start_hour * 60 + start_minute
    now_abs = now.hour * 60 + now.minute

    if slot_today_abs - now_abs < @booking_lead_time_hours * 60 do
      {:error, :insufficient_lead_time}
    else
      :ok
    end
  end

  defp persist_appointment(provider, patient, sh, sm, eh, em) do
    attrs = %{
      provider_id: provider.id,
      patient_id: patient.id,
      date: Date.utc_today(),
      start_hour: sh,
      start_minute: sm,
      end_hour: eh,
      end_minute: em,
      status: :confirmed
    }

    %Appointment{} |> Appointment.changeset(attrs) |> Repo.insert()
  end

  defp pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
end
```