```elixir
defmodule ScheduleAgent do
  @moduledoc "Shared Agent tracking appointments and resource availability."

  def start_link(_opts \\ []) do
    Agent.start_link(
      fn ->
        %{
          appointments: %{},
          resources: %{},
          cancellations: []
        }
      end,
      name: __MODULE__
    )
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}
  end
end

defmodule AppointmentBooker do
  @moduledoc "Books appointments and assigns resources."

  require Logger

  def book(agent, %{
        resource_id: resource_id,
        start_dt: start_dt,
        end_dt: end_dt,
        patient_id: patient_id,
        type: type
      } = params) do
    conflict? =
      Agent.get(agent, fn state ->
        state.appointments
        |> Map.values()
        |> Enum.any?(fn appt ->
          appt.resource_id == resource_id and
            appt.status != :cancelled and
            DateTime.compare(appt.start_dt, end_dt) == :lt and
            DateTime.compare(appt.end_dt, start_dt) == :gt
        end)
      end)

    if conflict? do
      {:error, :slot_not_available}
    else
      appt_id = "appt_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())

      appointment = %{
        id: appt_id,
        resource_id: resource_id,
        patient_id: patient_id,
        start_dt: start_dt,
        end_dt: end_dt,
        type: type,
        notes: Map.get(params, :notes, ""),
        status: :confirmed,
        booked_at: DateTime.utc_now()
      }

      Agent.update(agent, fn state ->
        %{state | appointments: Map.put(state.appointments, appt_id, appointment)}
      end)

      Logger.info("Booked #{type} appointment #{appt_id} for resource #{resource_id}")
      {:ok, appt_id}
    end
  end
end
defmodule AppointmentCanceller do
  @moduledoc "Handles appointment cancellations and waitlist promotion."

  require Logger

  def cancel(agent, appt_id, reason \\ :patient_request) do
    case Agent.get(agent, fn state -> Map.get(state.appointments, appt_id) end) do
      nil ->
        {:error, :not_found}

      %{status: :cancelled} ->
        {:error, :already_cancelled}

      appt ->
        Agent.update(agent, fn state ->
          cancelled = %{appt | status: :cancelled, cancelled_at: DateTime.utc_now()}

          cancellation_log = %{
            appt_id: appt_id,
            resource_id: appt.resource_id,
            reason: reason,
            at: DateTime.utc_now()
          }

          %{
            state
            | appointments: Map.put(state.appointments, appt_id, cancelled),
              cancellations: [cancellation_log | state.cancellations]
          }
        end)

        Logger.info("Cancelled appointment #{appt_id}: #{reason}")
        :ok
    end
  end
end
defmodule AvailabilityChecker do
  @moduledoc "Calculates free time slots for a given resource and day."

  def slots_available(agent, resource_id, date) do
    booked_ranges =
      Agent.get(agent, fn state ->
        state.appointments
        |> Map.values()
        |> Enum.filter(fn appt ->
          appt.resource_id == resource_id and
            appt.status != :cancelled and
            DateTime.to_date(appt.start_dt) == date
        end)
        |> Enum.map(&{&1.start_dt, &1.end_dt})
      end)

    all_slots = generate_slots(date, resource_id)

    Enum.reject(all_slots, fn {slot_start, slot_end} ->
      Enum.any?(booked_ranges, fn {booked_start, booked_end} ->
        DateTime.compare(booked_start, slot_end) == :lt and
          DateTime.compare(booked_end, slot_start) == :gt
      end)
    end)
  end

  defp generate_slots(date, _resource_id) do
    start_hour = 8
    end_hour = 17
    slot_minutes = 30

    for hour <- start_hour..(end_hour - 1),
        minute <- [0, slot_minutes],
        slot_minutes * 2 <= 60 do
      slot_start = DateTime.new!(date, Time.new!(hour, minute, 0))
      slot_end = DateTime.add(slot_start, slot_minutes * 60, :second)
      {slot_start, slot_end}
    end
  end
end
defmodule ScheduleExporter do
  @moduledoc "Exports daily schedule summaries for printing or external systems."

  def export_day(agent, date) do
    appointments =
      Agent.get(agent, fn state ->
        state.appointments
        |> Map.values()
        |> Enum.filter(fn appt ->
          DateTime.to_date(appt.start_dt) == date and appt.status != :cancelled
        end)
        |> Enum.sort_by(& &1.start_dt, DateTime)
      end)

    %{
      date: date,
      total: length(appointments),
      appointments:
        Enum.map(appointments, fn appt ->
          %{
            id: appt.id,
            resource: appt.resource_id,
            patient: appt.patient_id,
            start: appt.start_dt,
            end: appt.end_dt,
            type: appt.type
          }
        end)
    }
  end
end
```
