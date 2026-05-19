```elixir
defmodule SchedulerAgentStore do
  @moduledoc "Starts the shared scheduling agent."

  def start do
    {:ok, pid} = Agent.start_link(fn ->
      %{appointments: [], cancelled: [], blocked_slots: []}
    end)
    pid
  end
end

defmodule SchedulerPlanner do
  @moduledoc """
  Books new appointments into the scheduling agent.
  """

  def book(pid, appointment, resource_id, opts \\ []) do
    enriched = %{
      id: generate_id(),
      resource_id: resource_id,
      title: appointment[:title] || "Untitled",
      start_time: appointment[:start_time],
      end_time: appointment[:end_time],
      attendees: appointment[:attendees] || [],
      location: Keyword.get(opts, :location, :virtual),
      status: :confirmed,
      booked_at: DateTime.utc_now()
    }

    Agent.update(pid, fn state ->
      %{state | appointments: [enriched | state.appointments]}
    end)

    {:ok, enriched}
  end

  def list_all(pid) do
    Agent.get(pid, fn state -> state.appointments end)
  end

  defp generate_id do
    "appt_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
  end
end

defmodule SchedulerConflictChecker do
  @moduledoc """
  Checks whether a proposed time slot conflicts with existing appointments.
  """

  def has_conflict?(pid, resource_id, proposed_start, proposed_end) do
    Agent.get(pid, fn state ->
      Enum.any?(state.appointments, fn appt ->
        appt.resource_id == resource_id and
          appt.status == :confirmed and
          times_overlap?(appt.start_time, appt.end_time, proposed_start, proposed_end)
      end)
    end)
  end

  def conflicts_for(pid, resource_id) do
    Agent.get(pid, fn state ->
      Enum.filter(state.appointments, fn appt ->
        appt.resource_id == resource_id and appt.status == :confirmed
      end)
    end)
  end

  defp times_overlap?(a_start, a_end, b_start, b_end) do
    DateTime.compare(a_start, b_end) == :lt and
      DateTime.compare(b_start, a_end) == :lt
  end
end

defmodule SchedulerCancellation do
  @moduledoc """
  Handles appointment cancellations and updates agent state.
  """

  def cancel(pid, appointment_id, reason \\ :user_requested) do
    existing =
      Agent.get(pid, fn state ->
        Enum.find(state.appointments, fn a -> a.id == appointment_id end)
      end)

    case existing do
      nil ->
        {:error, :not_found}

      appt ->
        cancelled_entry = %{appt | status: :cancelled}

        Agent.update(pid, fn state ->
          updated_appointments =
            Enum.map(state.appointments, fn a ->
              if a.id == appointment_id, do: %{a | status: :cancelled}, else: a
            end)

          cancellation_record = %{
            appointment_id: appointment_id,
            resource_id: appt.resource_id,
            reason: reason,
            cancelled_at: DateTime.utc_now()
          }

          %{state |
            appointments: updated_appointments,
            cancelled: [cancellation_record | state.cancelled]
          }
        end)

        {:ok, cancelled_entry}
    end
  end
end

defmodule SchedulerCalendar do
  @moduledoc """
  Queries the scheduling agent to produce a calendar view for a given day.
  """

  def for_day(pid, date) do
    state = Agent.get(pid, fn s -> s end)

    day_appointments =
      Enum.filter(state.appointments, fn appt ->
        appt.status == :confirmed and
          Date.compare(DateTime.to_date(appt.start_time), date) == :eq
      end)
      |> Enum.sort_by(& &1.start_time, DateTime)

    cancelled_on_day =
      Enum.filter(state.cancelled, fn c ->
        Date.compare(DateTime.to_date(c.cancelled_at), date) == :eq
      end)

    %{
      date: date,
      confirmed: day_appointments,
      cancelled_today: length(cancelled_on_day),
      slot_count: length(day_appointments)
    }
  end
end
```
