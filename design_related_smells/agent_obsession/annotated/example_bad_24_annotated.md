# Annotated Example — Agent Obsession

| Field | Value |
|---|---|
| **Smell name** | Agent Obsession |
| **Expected smell location** | Multiple modules: `SchedulerPlanner`, `SchedulerConflictChecker`, `SchedulerCancellation`, `SchedulerCalendar` |
| **Affected functions** | `SchedulerPlanner.book/3`, `SchedulerConflictChecker.has_conflict?/3`, `SchedulerCancellation.cancel/2`, `SchedulerCalendar.for_day/2` |
| **Short explanation** | Four scheduling modules each directly manipulate a shared Agent holding appointment data. No module owns or encapsulates the agent; every module accesses its internal fields directly, spreading interaction responsibility across the codebase. |

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

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because SchedulerPlanner directly calls Agent.update/2
  # to write appointments into the shared agent state. It takes on ownership of the agent's
  # internal `appointments` list without any encapsulating layer.
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
  # VALIDATION: SMELL END
end

defmodule SchedulerConflictChecker do
  @moduledoc """
  Checks whether a proposed time slot conflicts with existing appointments.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because SchedulerConflictChecker directly calls Agent.get/2
  # to read the appointments list, creating a second module with direct, unmediated access
  # to the agent's internal state structure.
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
  # VALIDATION: SMELL END
end

defmodule SchedulerCancellation do
  @moduledoc """
  Handles appointment cancellations and updates agent state.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because SchedulerCancellation is a third module that directly
  # reads and writes the agent using Agent.get/2 and Agent.update/2. It mutates both
  # `appointments` and `cancelled` fields, relying on implicit knowledge of the state shape.
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
  # VALIDATION: SMELL END
end

defmodule SchedulerCalendar do
  @moduledoc """
  Queries the scheduling agent to produce a calendar view for a given day.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because SchedulerCalendar is a fourth module directly
  # calling Agent.get/2 on the shared state. The full agent state map is read and
  # interpreted here, tying this module to the same implicit internal structure.
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
  # VALIDATION: SMELL END
end
```
