```elixir
defmodule AppointmentScheduler do
  @moduledoc """
  Handles appointment booking, rescheduling, and cancellation for a clinic system.
  """

  alias Scheduling.{Appointment, Provider, BlockedDate, Availability, NotificationService}

  @business_hours_start {8, 0}
  @business_hours_end {18, 0}
  @slot_duration_minutes 30
  @min_advance_hours 2

  def book(provider_id, booking_params) do
    with {:ok, provider} <- Provider.fetch(provider_id),
         {:ok, start_dt} <- parse_datetime(booking_params.start_at),
         :ok <- check_advance_notice(start_dt),
         :ok <- check_business_hours(start_dt),
         :ok <- check_not_blocked(provider_id, DateTime.to_date(start_dt)),
         :ok <- check_no_conflict(provider_id, start_dt) do

      end_dt = DateTime.add(start_dt, @slot_duration_minutes * 60, :second)

      appointment = %Appointment{
        id: Ecto.UUID.generate(),
        provider_id: provider_id,
        patient_id: booking_params.patient_id,
        start_at: start_dt,
        end_at: end_dt,
        reason: booking_params.reason,
        status: :confirmed,
        booked_at: DateTime.utc_now()
      }

      Availability.mark_busy(provider_id, start_dt, end_dt)
      Scheduling.Repo.insert(appointment)
      NotificationService.send_confirmation(appointment)
      {:ok, appointment}
    end
  end

  def reschedule(appointment_id, provider_id, new_params) do
    with {:ok, appointment} <- Appointment.fetch(appointment_id),
         :ok <- check_reschedule_allowed(appointment),
         {:ok, new_start} <- parse_datetime(new_params.start_at),
         :ok <- check_advance_notice(new_start),
         :ok <- check_business_hours(new_start),
         :ok <- check_not_blocked(provider_id, DateTime.to_date(new_start)),
         :ok <- check_no_conflict(provider_id, new_start) do

      new_end = DateTime.add(new_start, @slot_duration_minutes * 60, :second)

      Availability.release(provider_id, appointment.start_at, appointment.end_at)
      Availability.mark_busy(provider_id, new_start, new_end)

      updated =
        Appointment.update(appointment, %{
          start_at: new_start,
          end_at: new_end,
          rescheduled_at: DateTime.utc_now()
        })

      NotificationService.send_reschedule(updated)
      {:ok, updated}
    end
  end

  def cancel(appointment_id, reason) do
    with {:ok, appointment} <- Appointment.fetch(appointment_id),
         :ok <- check_cancellation_allowed(appointment) do
      Availability.release(
        appointment.provider_id,
        appointment.start_at,
        appointment.end_at
      )

      updated = Appointment.update(appointment, %{status: :cancelled, cancel_reason: reason})
      NotificationService.send_cancellation(updated)
      {:ok, updated}
    end
  end

  defp check_business_hours(dt) do
    {h, m, _} = Time.to_erl(DateTime.to_time(dt))
    start_minutes = elem(@business_hours_start, 0) * 60 + elem(@business_hours_start, 1)
    end_minutes = elem(@business_hours_end, 0) * 60 + elem(@business_hours_end, 1)
    slot_minutes = h * 60 + m

    if slot_minutes >= start_minutes and slot_minutes + @slot_duration_minutes <= end_minutes do
      :ok
    else
      {:error, :outside_business_hours}
    end
  end

  defp check_not_blocked(provider_id, date) do
    case BlockedDate.fetch(provider_id, date) do
      {:ok, _} -> {:error, :date_blocked}
      {:error, :not_found} -> :ok
    end
  end

  defp check_no_conflict(provider_id, start_dt) do
    end_dt = DateTime.add(start_dt, @slot_duration_minutes * 60, :second)

    case Appointment.find_conflicting(provider_id, start_dt, end_dt) do
      [] -> :ok
      _ -> {:error, :time_slot_unavailable}
    end
  end

  defp check_advance_notice(start_dt) do
    min_start = DateTime.add(DateTime.utc_now(), @min_advance_hours * 3_600, :second)

    if DateTime.compare(start_dt, min_start) == :lt do
      {:error, :insufficient_advance_notice}
    else
      :ok
    end
  end

  defp check_reschedule_allowed(%{status: :cancelled}), do: {:error, :cannot_reschedule_cancelled}
  defp check_reschedule_allowed(_), do: :ok

  defp check_cancellation_allowed(%{start_at: start_at}) do
    if DateTime.compare(start_at, DateTime.utc_now()) == :lt do
      {:error, :appointment_in_past}
    else
      :ok
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, {:invalid_datetime, value}}
    end
  end
  defp parse_datetime(%DateTime{} = dt), do: {:ok, dt}
end
```
