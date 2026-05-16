# Annotated Example — Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `Scheduling.AppointmentService.find_slots/2`, around the `opts[:format]` and `opts[:first_only]` checks
- **Affected function(s):** `find_slots/2`
- **Short explanation:** The function can return a `%DateTime{}`, a list of `%DateTime{}`, or a list of formatted time strings depending on options, making it impossible to handle the result uniformly without inspecting the opts at the call-site.

---

```elixir
defmodule Scheduling.AppointmentService do
  @moduledoc """
  Manages appointment scheduling, slot availability, and booking
  for a multi-provider healthcare scheduling system.
  """

  alias Scheduling.Repo
  alias Scheduling.Schema.{Appointment, Provider, BlockedSlot}

  @slot_duration_minutes 30
  @max_advance_days 60

  @doc """
  Finds available appointment slots for a provider within a date range.

  ## Options

    * `:start_date` — `Date.t()` to begin searching from. Defaults to today.
    * `:end_date` — `Date.t()` to search until. Defaults to 14 days ahead.
    * `:duration_minutes` — Duration of the desired appointment. Defaults to #{@slot_duration_minutes}.
    * `:first_only` — When `true`, returns just the first available
      `%DateTime{}` instead of the full list. Returns `nil` if none found.
    * `:format` — When `:string`, returns a list of formatted strings
      like `"Mon 3 Jun, 09:00"` instead of `%DateTime{}` structs.

  ## Examples

      iex> find_slots(provider_id)
      [~U[2024-06-03 09:00:00Z], ~U[2024-06-03 09:30:00Z], ...]

      iex> find_slots(provider_id, first_only: true)
      ~U[2024-06-03 09:00:00Z]

      iex> find_slots(provider_id, format: :string)
      ["Mon 3 Jun, 09:00", "Mon 3 Jun, 09:30", ...]

  """

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because the return type changes from a list of
  # VALIDATION: DateTime structs, to a single DateTime (or nil), to a list of
  # VALIDATION: plain strings depending on the opts. A caller who pipe-chains
  # VALIDATION: this result cannot write a single Enum operation that is
  # VALIDATION: safe across all opt combinations.
  def find_slots(provider_id, opts \\ []) do
    start_date = Keyword.get(opts, :start_date, Date.utc_today())
    end_date = Keyword.get(opts, :end_date, Date.add(Date.utc_today(), 14))
    duration = Keyword.get(opts, :duration_minutes, @slot_duration_minutes)

    provider = Repo.get!(Provider, provider_id)
    blocked = blocked_slots(provider_id, start_date, end_date)
    booked = booked_slots(provider_id, start_date, end_date)
    unavailable = MapSet.union(blocked, booked)

    all_slots =
      date_range_to_slots(start_date, end_date, provider.working_hours, duration)
      |> Enum.reject(&MapSet.member?(unavailable, &1))

    cond do
      opts[:first_only] == true ->
        List.first(all_slots)

      opts[:format] == :string ->
        Enum.map(all_slots, &format_slot/1)

      true ->
        all_slots
    end
  end
  # VALIDATION: SMELL END

  defp date_range_to_slots(start_date, end_date, working_hours, duration_minutes) do
    Date.range(start_date, end_date)
    |> Enum.flat_map(fn date ->
      day_of_week = Date.day_of_week(date)
      hours = Map.get(working_hours, day_of_week, [])

      Enum.flat_map(hours, fn {start_time, end_time} ->
        generate_slots(date, start_time, end_time, duration_minutes)
      end)
    end)
  end

  defp generate_slots(date, start_time, end_time, duration) do
    slot_start = DateTime.new!(date, start_time, "Etc/UTC")
    slot_end = DateTime.new!(date, end_time, "Etc/UTC")
    total_minutes = DateTime.diff(slot_end, slot_start, :minute)
    count = div(total_minutes, duration)

    Enum.map(0..(count - 1), fn i ->
      DateTime.add(slot_start, i * duration * 60, :second)
    end)
  end

  defp blocked_slots(provider_id, start_date, end_date) do
    BlockedSlot
    |> Repo.all_by(provider_id: provider_id)
    |> Enum.filter(fn slot ->
      d = DateTime.to_date(slot.blocked_at)
      Date.compare(d, start_date) != :lt and Date.compare(d, end_date) != :gt
    end)
    |> Enum.map(& &1.blocked_at)
    |> MapSet.new()
  end

  defp booked_slots(provider_id, start_date, end_date) do
    Appointment
    |> Repo.all_by(provider_id: provider_id, status: :confirmed)
    |> Enum.filter(fn appt ->
      d = DateTime.to_date(appt.starts_at)
      Date.compare(d, start_date) != :lt and Date.compare(d, end_date) != :gt
    end)
    |> Enum.map(& &1.starts_at)
    |> MapSet.new()
  end

  defp format_slot(%DateTime{} = dt) do
    day_name = Calendar.strftime(dt, "%a")
    "#{day_name} #{dt.day} #{month_name(dt.month)}, #{Calendar.strftime(dt, "%H:%M")}"
  end

  defp month_name(m),
    do: ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec) |> Enum.at(m - 1)

  @doc """
  Books an appointment for a patient with a provider at the given slot.
  """
  def book(provider_id, patient_id, starts_at, duration_minutes \\ @slot_duration_minutes) do
    ends_at = DateTime.add(starts_at, duration_minutes * 60, :second)

    %Appointment{}
    |> Appointment.changeset(%{
      provider_id: provider_id,
      patient_id: patient_id,
      starts_at: starts_at,
      ends_at: ends_at,
      status: :confirmed
    })
    |> Repo.insert()
  end
end
```
