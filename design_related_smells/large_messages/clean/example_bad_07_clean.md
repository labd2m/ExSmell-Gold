```elixir
defmodule Scheduling.TimeSlot do
  defstruct [:start_time, :end_time, :type, :location, :notes]
end

defmodule Scheduling.Employee do
  @enforce_keys [:id, :name, :role]
  defstruct [
    :id,
    :name,
    :role,
    :department,
    :contract_hours_per_week,
    :skills,
    :preferences,
    :availability_windows,
    :booked_events,
    :time_off_requests
  ]
end

defmodule Scheduling.CalendarStore do
  @moduledoc "Simulates fetching the full scheduling calendar for a planning period."

  @spec load_snapshot(Date.t(), Date.t()) :: list(Scheduling.Employee.t())
  def load_snapshot(_from, _to) do
    Enum.map(1..2_000, fn i ->
      %Scheduling.Employee{
        id: "EMP-#{i}",
        name: "Employee #{i}",
        role: Enum.random(["engineer", "analyst", "manager", "support"]),
        department: "dept-#{rem(i, 20)}",
        contract_hours_per_week: 40,
        skills: ["skill-#{rem(i, 10)}", "skill-#{rem(i * 2, 10)}"],
        preferences: %{
          preferred_shift: Enum.random(["morning", "afternoon", "night"]),
          max_consecutive_days: 5,
          prefers_remote: rem(i, 3) == 0
        },
        availability_windows: Enum.map(0..6, fn day ->
          %Scheduling.TimeSlot{
            start_time: ~T[08:00:00],
            end_time: ~T[18:00:00],
            type: :available,
            location: "office",
            notes: "Day #{day}"
          }
        end),
        booked_events: Enum.map(1..30, fn j ->
          %Scheduling.TimeSlot{
            start_time: Time.add(~T[09:00:00], j * 1800, :second),
            end_time: Time.add(~T[10:00:00], j * 1800, :second),
            type: :meeting,
            location: "room-#{rem(j, 10)}",
            notes: "Meeting #{j} for EMP-#{i}"
          }
        end),
        time_off_requests: Enum.map(1..3, fn k ->
          %{from: Date.utc_today(), to: Date.utc_today() |> Date.add(k), status: :approved}
        end)
      }
    end)
  end
end

defmodule Scheduling.ShiftOptimizer do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{schedules: []}, opts)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:optimize, employees, options}, _from, state) do
    result =
      employees
      |> Enum.filter(&(length(&1.skills) >= Map.get(options, :min_skills, 1)))
      |> Enum.map(fn emp ->
        %{
          employee_id: emp.id,
          assigned_shift: emp.preferences.preferred_shift,
          total_hours: emp.contract_hours_per_week
        }
      end)

    {:reply, {:ok, result}, %{state | schedules: [result | state.schedules]}}
  end
end

defmodule Scheduling.OptimizerClient do
  @moduledoc "Prepares the calendar snapshot and requests shift optimization."

  require Logger

  @spec optimize(pid(), map()) :: {:ok, list()} | {:error, term()}
  def optimize(optimizer_pid, options) do
    date_from = Date.utc_today()
    date_to = Date.add(date_from, 14)

    Logger.info("Loading calendar snapshot for #{date_from} to #{date_to}")

    employees = Scheduling.CalendarStore.load_snapshot(date_from, date_to)

    Logger.info("Loaded #{length(employees)} employee records — calling optimizer")

    result = GenServer.call(optimizer_pid, {:optimize, employees, options}, :infinity)

    case result do
      {:ok, schedule} ->
        Logger.info("Optimization complete — #{length(schedule)} assignments produced")
        {:ok, schedule}

      error ->
        Logger.error("Optimization failed: #{inspect(error)}")
        {:error, error}
    end
  end
end
```
