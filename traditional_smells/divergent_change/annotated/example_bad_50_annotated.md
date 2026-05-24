# Annotated Example — Code Smell Validation

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** The entire `SchedulingManager` module
- **Affected function(s):** `create_shift/3`, `cancel_shift/2`, `list_shifts/2`, `assign_employee/2`, `unassign_employee/2`, `employee_availability/2`, `book_resource/3`, `release_resource/2`, `resource_calendar/2`
- **Short explanation:** The `SchedulingManager` module intermingles three unrelated concerns: shift scheduling (create/cancel/list shifts), employee assignment and availability, and meeting room/resource reservation. A change in overtime rules affects only employee functions; a new room booking policy affects only resource functions; a change in shift notification requirements affects only shift functions — three independent reasons to edit one module.

---

```elixir
defmodule MyApp.SchedulingManager do
  @moduledoc """
  Manages work shifts and their assignments, tracks employee availability,
  and handles bookable resource reservations (rooms, equipment).
  """

  alias MyApp.Repo
  alias MyApp.Scheduling.{Shift, ShiftAssignment, EmployeeAvailability}
  alias MyApp.Resources.{Resource, ResourceBooking}
  import Ecto.Query

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module owns three independent responsibility
  # VALIDATION: clusters. Shift management changes when rostering rules or approval
  # VALIDATION: workflows change. Employee availability changes when HR policies or
  # VALIDATION: overtime regulations change. Resource booking changes when room capacity
  # VALIDATION: rules or equipment loan policies change. All three are unrelated reasons
  # VALIDATION: to edit this single module.

  # ── Reason to modify (1): Shift scheduling ─────────────────────────────────

  @max_shift_hours 12

  def create_shift(location_id, starts_at, ends_at) do
    duration_hours = DateTime.diff(ends_at, starts_at, :second) / 3600

    cond do
      DateTime.compare(starts_at, ends_at) != :lt ->
        {:error, :invalid_time_range}

      duration_hours > @max_shift_hours ->
        {:error, {:exceeds_max_shift_hours, @max_shift_hours}}

      shift_overlap_exists?(location_id, starts_at, ends_at) ->
        {:error, :overlapping_shift_exists}

      true ->
        %Shift{}
        |> Shift.changeset(%{
          location_id: location_id,
          starts_at: starts_at,
          ends_at: ends_at,
          status: :open
        })
        |> Repo.insert()
    end
  end

  def cancel_shift(shift_id, reason) do
    shift = Repo.get!(Shift, shift_id)

    if shift.status in [:completed, :cancelled] do
      {:error, :cannot_cancel}
    else
      Repo.transaction(fn ->
        from(a in ShiftAssignment, where: a.shift_id == ^shift_id)
        |> Repo.update_all(set: [status: :cancelled])

        shift
        |> Shift.changeset(%{status: :cancelled, cancellation_reason: reason})
        |> Repo.update!()
      end)
    end
  end

  def list_shifts(location_id, date) do
    start_of_day = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end_of_day = DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

    from(s in Shift,
      where:
        s.location_id == ^location_id and
          s.starts_at >= ^start_of_day and
          s.starts_at <= ^end_of_day,
      order_by: s.starts_at,
      preload: [:assignments]
    )
    |> Repo.all()
  end

  defp shift_overlap_exists?(location_id, starts_at, ends_at) do
    from(s in Shift,
      where:
        s.location_id == ^location_id and
          s.status != :cancelled and
          s.starts_at < ^ends_at and
          s.ends_at > ^starts_at
    )
    |> Repo.exists?()
  end

  # ── Reason to modify (2): Employee assignment & availability ───────────────

  @max_hours_per_week 40

  def assign_employee(shift_id, employee_id) do
    shift = Repo.get!(Shift, shift_id)

    with :ok <- check_weekly_hours(employee_id, shift),
         :ok <- check_availability(employee_id, shift.starts_at, shift.ends_at) do
      %ShiftAssignment{}
      |> ShiftAssignment.changeset(%{
        shift_id: shift_id,
        employee_id: employee_id,
        status: :confirmed
      })
      |> Repo.insert()
    end
  end

  def unassign_employee(shift_id, employee_id) do
    case Repo.get_by(ShiftAssignment, shift_id: shift_id, employee_id: employee_id) do
      nil -> {:error, :assignment_not_found}
      assignment -> Repo.delete(assignment)
    end
  end

  def employee_availability(employee_id, week_start) do
    week_end = Date.add(week_start, 6)

    from(a in EmployeeAvailability,
      where:
        a.employee_id == ^employee_id and
          a.date >= ^week_start and
          a.date <= ^week_end,
      order_by: a.date
    )
    |> Repo.all()
  end

  defp check_weekly_hours(employee_id, shift) do
    week_start = DateTime.to_date(shift.starts_at) |> Date.beginning_of_week()
    week_end = Date.add(week_start, 6)

    booked_seconds =
      from(a in ShiftAssignment,
        join: s in Shift,
        on: s.id == a.shift_id,
        where:
          a.employee_id == ^employee_id and
            a.status == :confirmed and
            fragment("?::date", s.starts_at) >= ^week_start and
            fragment("?::date", s.starts_at) <= ^week_end,
        select: sum(fragment("EXTRACT(EPOCH FROM (? - ?))", s.ends_at, s.starts_at))
      )
      |> Repo.one() || 0

    shift_seconds = DateTime.diff(shift.ends_at, shift.starts_at)
    total_hours = (booked_seconds + shift_seconds) / 3600

    if total_hours > @max_hours_per_week do
      {:error, {:exceeds_weekly_hours, @max_hours_per_week}}
    else
      :ok
    end
  end

  defp check_availability(employee_id, starts_at, ends_at) do
    conflict =
      from(a in ShiftAssignment,
        join: s in Shift,
        on: s.id == a.shift_id,
        where:
          a.employee_id == ^employee_id and
            a.status == :confirmed and
            s.starts_at < ^ends_at and
            s.ends_at > ^starts_at
      )
      |> Repo.exists?()

    if conflict, do: {:error, :employee_schedule_conflict}, else: :ok
  end

  # ── Reason to modify (3): Bookable resource reservations ───────────────────

  def book_resource(resource_id, starts_at, ends_at) do
    resource = Repo.get!(Resource, resource_id)

    if resource_booking_conflict?(resource_id, starts_at, ends_at) do
      {:error, :resource_unavailable}
    else
      %ResourceBooking{}
      |> ResourceBooking.changeset(%{
        resource_id: resource_id,
        starts_at: starts_at,
        ends_at: ends_at,
        status: :confirmed
      })
      |> Repo.insert()
    end
  end

  def release_resource(booking_id) do
    case Repo.get(ResourceBooking, booking_id) do
      nil -> {:error, :not_found}
      booking -> Repo.delete(booking)
    end
  end

  def resource_calendar(resource_id, date) do
    start_of_day = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end_of_day = DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

    from(b in ResourceBooking,
      where:
        b.resource_id == ^resource_id and
          b.starts_at >= ^start_of_day and
          b.starts_at <= ^end_of_day and
          b.status == :confirmed,
      order_by: b.starts_at
    )
    |> Repo.all()
  end

  defp resource_booking_conflict?(resource_id, starts_at, ends_at) do
    from(b in ResourceBooking,
      where:
        b.resource_id == ^resource_id and
          b.status == :confirmed and
          b.starts_at < ^ends_at and
          b.ends_at > ^starts_at
    )
    |> Repo.exists?()
  end

  # VALIDATION: SMELL END
end
```
