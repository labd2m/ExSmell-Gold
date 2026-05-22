```elixir
defmodule Healthcare.TimeZoneUtils do
  @moduledoc """
  Time-zone conversion and offset utilities used across the healthcare scheduling platform.
  """

  @tz_offsets %{
    "America/New_York"    => -5,
    "America/Chicago"     => -6,
    "America/Denver"      => -7,
    "America/Los_Angeles" => -8,
    "Europe/London"       => 0,
    "Europe/Berlin"       => 1,
    "Asia/Tokyo"          => 9
  }

  def to_utc(naive_datetime, tz_name) do
    offset = Map.get(@tz_offsets, tz_name, 0)
    NaiveDateTime.add(naive_datetime, -offset * 3600, :second)
    |> DateTime.from_naive!("Etc/UTC")
  end

  def from_utc(datetime, tz_name) do
    offset = Map.get(@tz_offsets, tz_name, 0)
    DateTime.add(datetime, offset * 3600, :second)
  end

  def format_with_tz(datetime, tz_name) do
    local = from_utc(datetime, tz_name)
    "#{NaiveDateTime.to_string(DateTime.to_naive(local))} #{tz_name}"
  end
end

defmodule Healthcare.CalendarHelpers do
  @moduledoc """
  Appointment slot generation and availability helpers shared across healthcare
  scheduling modules via `use`.
  """

  @slot_duration_minutes 30

  defmacro __using__(_opts) do
    quote do
      import Healthcare.TimeZoneUtils  # propagates timezone dependency into every caller

      def generate_slots(date, start_time, end_time) do
        start_min = start_time.hour * 60 + start_time.minute
        end_min   = end_time.hour * 60 + end_time.minute
        slot_dur  = unquote(@slot_duration_minutes)

        start_min
        |> Stream.iterate(&(&1 + slot_dur))
        |> Enum.take_while(&(&1 + slot_dur <= end_min))
        |> Enum.map(fn min ->
          h = div(min, 60)
          m = rem(min, 60)
          {:ok, slot_start} = Time.new(h, m, 0)
          {:ok, slot_end}   = Time.new(div(min + slot_dur, 60), rem(min + slot_dur, 60), 0)
          %{date: date, start: slot_start, end: slot_end}
        end)
      end

      def available_slots(slots, existing_appts) do
        booked_times = MapSet.new(existing_appts, & &1.slot.start)
        Enum.reject(slots, fn slot -> MapSet.member?(booked_times, slot.start) end)
      end

      def slot_conflict?(slot, existing_appts) do
        Enum.any?(existing_appts, fn a ->
          a.slot.date == slot.date and a.slot.start == slot.start
        end)
      end
    end
  end
end

defmodule Healthcare.AppointmentManager do
  @moduledoc """
  Manages patient appointments: scheduling, rescheduling, cancellation,
  provider availability, and reminder dispatch coordination.
  """

  use Healthcare.CalendarHelpers

  @work_start ~T[08:00:00]
  @work_end   ~T[17:00:00]
  @cancel_cutoff_hours 24

  def book(provider, patient, date, preferred_slot) do
    existing = provider_appointments(provider, date)
    slots    = generate_slots(date, @work_start, @work_end)

    with true <- date_in_future?(date),
         false <- slot_conflict?(preferred_slot, existing),
         true  <- preferred_slot in slots do
      appt = %{
        id:          appt_id(),
        provider_id: provider.id,
        patient_id:  patient.id,
        slot:        preferred_slot,
        status:      :confirmed,
        notes:       nil,
        booked_at:   DateTime.utc_now()
      }

      {:ok, appt}
    else
      false -> {:error, :date_in_past}
      true  -> {:error, :slot_unavailable}
      _     -> {:error, :invalid_slot}
    end
  end

  def reschedule(%{status: :confirmed} = appt, provider, new_slot) do
    date     = new_slot.date
    existing = provider_appointments(provider, date) |> Enum.reject(&(&1.id == appt.id))

    if slot_conflict?(new_slot, existing) do
      {:error, :slot_unavailable}
    else
      {:ok, %{appt | slot: new_slot, status: :rescheduled, rescheduled_at: DateTime.utc_now()}}
    end
  end

  def reschedule(_, _, _), do: {:error, :cannot_reschedule}

  def cancel(%{status: :confirmed} = appt) do
    appt_datetime = NaiveDateTime.new!(appt.slot.date, appt.slot.start)
    appt_utc      = to_utc(appt_datetime, "Etc/UTC")
    hours_until   = DateTime.diff(appt_utc, DateTime.utc_now(), :second) / 3600

    if hours_until >= @cancel_cutoff_hours do
      {:ok, %{appt | status: :cancelled, cancelled_at: DateTime.utc_now()}}
    else
      {:error, :cancellation_window_passed}
    end
  end

  def cancel(_), do: {:error, :cannot_cancel}

  def open_slots(provider, date) do
    existing = provider_appointments(provider, date)
    all      = generate_slots(date, @work_start, @work_end)
    available_slots(all, existing)
  end

  def summarize_day(provider, date) do
    appts = provider_appointments(provider, date)

    %{
      date:       date,
      booked:     length(appts),
      open:       length(open_slots(provider, date)),
      cancelled:  Enum.count(appts, &(&1.status == :cancelled))
    }
  end

  defp date_in_future?(date) do
    Date.compare(date, Date.utc_today()) in [:gt, :eq]
  end

  defp provider_appointments(provider, date) do
    provider.appointments |> Enum.filter(&(&1.slot.date == date))
  end

  defp appt_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false) |> then(&"APT-#{&1}")
  end
end
```
