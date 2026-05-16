# Code Smell: Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `Scheduling.Appointment.find_slots/2`
- **Affected function(s):** `find_slots/2`
- **Short explanation:** The `:return` option changes the result from a list of `DateTime` structs, to a list of `{DateTime, DateTime}` start/end tuples, to a grouped map by date. Callers cannot treat the return value uniformly without tracking the option.

---

```elixir
defmodule MyApp.Scheduling.Appointment do
  @moduledoc """
  Manages appointment scheduling, slot availability queries, and booking
  confirmation for multi-provider calendars. Used by the patient-facing
  booking portal and internal staff scheduling tools.
  """

  alias MyApp.Scheduling.Calendar
  alias MyApp.Scheduling.Provider
  alias MyApp.Scheduling.BlockedPeriod
  alias MyApp.Repo

  @slot_duration_minutes 30
  @booking_horizon_days 60
  @min_advance_minutes 60

  defstruct [
    :id, :provider_id, :patient_id,
    :starts_at, :ends_at, :status,
    :notes, :created_at
  ]

  def new(provider_id, patient_id, starts_at, opts \\ []) do
    duration = Keyword.get(opts, :duration_minutes, @slot_duration_minutes)

    %__MODULE__{
      id: generate_id(),
      provider_id: provider_id,
      patient_id: patient_id,
      starts_at: starts_at,
      ends_at: DateTime.add(starts_at, duration * 60, :second),
      status: :pending,
      notes: opts[:notes],
      created_at: DateTime.utc_now()
    }
  end

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because opts[:return] produces incompatible types:
  # :starts returns a flat list of DateTime values (slot start times only),
  # :ranges returns a list of {DateTime, DateTime} tuples (start and end),
  # and :grouped returns a map of %{Date => [DateTime]} grouping starts by date.
  # All three are used in practice (e.g., dropdowns vs. calendar grid vs. range pickers),
  # but packing them into one function with an option makes the return type opaque.
  def find_slots(provider_id, opts \\ []) when is_list(opts) do
    return = Keyword.get(opts, :return, :starts)
    from = Keyword.get(opts, :from, DateTime.utc_now())
    days_ahead = Keyword.get(opts, :days_ahead, 7)
    duration = Keyword.get(opts, :duration_minutes, @slot_duration_minutes)
    exclude_booked = Keyword.get(opts, :exclude_booked, true)

    horizon = DateTime.add(from, days_ahead * 86_400, :second)

    working_hours = Calendar.working_hours(provider_id, from, horizon)
    blocked = if exclude_booked, do: BlockedPeriod.for_provider(provider_id, from, horizon), else: []

    raw_slots =
      working_hours
      |> expand_to_slots(duration)
      |> Enum.reject(fn slot_start ->
        slot_end = DateTime.add(slot_start, duration * 60, :second)
        Enum.any?(blocked, &overlaps?(&1, slot_start, slot_end))
      end)
      |> Enum.filter(fn s ->
        DateTime.diff(s, DateTime.utc_now()) >= @min_advance_minutes * 60
      end)

    case return do
      :starts ->
        raw_slots

      :ranges ->
        Enum.map(raw_slots, fn s ->
          {s, DateTime.add(s, duration * 60, :second)}
        end)

      :grouped ->
        Enum.group_by(raw_slots, fn s ->
          DateTime.to_date(s)
        end)
    end
  end
  # VALIDATION: SMELL END

  def book(%__MODULE__{} = appt) do
    with :ok <- validate_slot_available(appt),
         {:ok, saved} <- Repo.insert(appt) do
      {:ok, %{saved | status: :confirmed}}
    end
  end

  def cancel(%__MODULE__{} = appt, reason \\ nil) do
    %{appt | status: {:cancelled, reason}}
  end

  defp expand_to_slots(working_hours, duration_minutes) do
    Enum.flat_map(working_hours, fn {from, to} ->
      Stream.iterate(from, &DateTime.add(&1, duration_minutes * 60, :second))
      |> Enum.take_while(&(DateTime.compare(&1, to) == :lt))
    end)
  end

  defp overlaps?(blocked, slot_start, slot_end) do
    DateTime.compare(blocked.starts_at, slot_end) == :lt and
      DateTime.compare(blocked.ends_at, slot_start) == :gt
  end

  defp validate_slot_available(_appt), do: :ok

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
