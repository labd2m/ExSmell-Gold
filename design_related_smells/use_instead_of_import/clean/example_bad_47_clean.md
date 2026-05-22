```elixir
defmodule CalendarUtils do
  def next_weekday(date) do
    case Date.day_of_week(date) do
      6 -> Date.add(date, 2)
      7 -> Date.add(date, 1)
      _ -> date
    end
  end

  def overlap?(start_a, end_a, start_b, end_b) do
    DateTime.compare(start_a, end_b) == :lt and
    DateTime.compare(end_a, start_b) == :gt
  end

  def slot_end(start, duration_minutes) do
    DateTime.add(start, duration_minutes * 60, :second)
  end

  def same_day?(dt_a, dt_b) do
    DateTime.to_date(dt_a) == DateTime.to_date(dt_b)
  end
end

defmodule SchedulingHelpers do
  defmacro __using__(_opts) do
    quote do
      import CalendarUtils

      def slots_for_day(date, start_hour, end_hour, duration_mins) do
        start_dt = DateTime.new!(date, Time.new!(start_hour, 0, 0))
        end_dt   = DateTime.new!(date, Time.new!(end_hour, 0, 0))

        Stream.iterate(start_dt, &DateTime.add(&1, duration_mins * 60, :second))
        |> Stream.take_while(&(DateTime.compare(&1, end_dt) == :lt))
        |> Enum.map(fn s -> {s, slot_end(s, duration_mins)} end)
      end

      def conflict?(existing_appointments, start_dt, end_dt) do
        Enum.any?(existing_appointments, fn appt ->
          overlap?(start_dt, end_dt, appt.start_dt, appt.end_dt)
        end)
      end
    end
  end
end

defmodule AppointmentScheduler do
  use SchedulingHelpers

  @default_duration  30
  @working_hours     {8, 18}
  @max_advance_days  90

  def schedule(request, existing_appointments) do
    start_dt = request.preferred_start
    duration = request.duration_minutes || @default_duration
    end_dt   = slot_end(start_dt, duration)

    cond do
      past?(start_dt) ->
        {:error, :start_in_past}
      too_far_ahead?(start_dt) ->
        {:error, :exceeds_advance_booking_window}
      not within_working_hours?(start_dt, end_dt) ->
        {:error, :outside_working_hours}
      conflict?(existing_appointments, start_dt, end_dt) ->
        {:error, :time_slot_conflict}
      true ->
        {:ok, build_appointment(request, start_dt, end_dt)}
    end
  end

  def available_slots(provider, date) do
    {start_h, end_h} = @working_hours
    all_slots        = slots_for_day(next_weekday(date), start_h, end_h, @default_duration)

    Enum.reject(all_slots, fn {s, e} ->
      conflict?(provider.appointments, s, e)
    end)
  end

  def reschedule(appointment, new_start, existing_appointments) do
    end_dt = slot_end(new_start, appointment.duration_minutes)
    others = Enum.reject(existing_appointments, &(&1.id == appointment.id))

    cond do
      past?(new_start) ->
        {:error, :start_in_past}
      conflict?(others, new_start, end_dt) ->
        {:error, :time_slot_conflict}
      same_day?(appointment.start_dt, new_start) ->
        {:ok, %{appointment | start_dt: new_start, end_dt: end_dt, status: :rescheduled}}
      true ->
        {:ok, %{appointment | start_dt: new_start, end_dt: end_dt, status: :rescheduled}}
    end
  end

  def appointments_for_day(provider, date) do
    Enum.filter(provider.appointments, fn appt ->
      same_day?(appt.start_dt, DateTime.new!(date, ~T[00:00:00]))
    end)
  end

  defp build_appointment(request, start_dt, end_dt) do
    %{
      id:           "appt_#{:erlang.unique_integer([:positive])}",
      provider_id:  request.provider_id,
      patient_id:   request.patient_id,
      start_dt:     start_dt,
      end_dt:       end_dt,
      duration_minutes: request.duration_minutes || @default_duration,
      reason:       request.reason,
      status:       :scheduled,
      booked_at:    DateTime.utc_now()
    }
  end

  defp past?(dt), do: DateTime.compare(dt, DateTime.utc_now()) == :lt

  defp too_far_ahead?(dt) do
    limit = DateTime.add(DateTime.utc_now(), @max_advance_days * 86_400, :second)
    DateTime.compare(dt, limit) == :gt
  end

  defp within_working_hours?(start_dt, end_dt) do
    {start_h, end_h} = @working_hours
    s = start_dt.hour
    e = end_dt.hour
    s >= start_h and e <= end_h
  end
end
```
