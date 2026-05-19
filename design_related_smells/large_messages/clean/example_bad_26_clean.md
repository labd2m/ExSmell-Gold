```elixir
defmodule Scheduling.Attendee do
  defstruct [:employee_id, :name, :email, :response, :is_organiser]

  @type t :: %__MODULE__{
          employee_id: String.t(),
          name: String.t(),
          email: String.t(),
          response: :accepted | :declined | :tentative | :pending,
          is_organiser: boolean()
        }
end

defmodule Scheduling.RecurrenceRule do
  defstruct [:freq, :interval, :until, :by_day, :exceptions]

  @type t :: %__MODULE__{
          freq: :daily | :weekly | :monthly,
          interval: non_neg_integer(),
          until: Date.t() | nil,
          by_day: [String.t()],
          exceptions: [Date.t()]
        }
end

defmodule Scheduling.CalendarEvent do
  @enforce_keys [:id, :title, :starts_at, :ends_at, :room_id, :attendees]
  defstruct [
    :id,
    :title,
    :starts_at,
    :ends_at,
    :room_id,
    :attendees,
    :description,
    :recurrence,
    :tags,
    :conference_link,
    :created_by,
    :last_modified_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          starts_at: DateTime.t(),
          ends_at: DateTime.t(),
          room_id: String.t(),
          attendees: [Scheduling.Attendee.t()],
          description: String.t() | nil,
          recurrence: Scheduling.RecurrenceRule.t() | nil,
          tags: [String.t()],
          conference_link: String.t() | nil,
          created_by: String.t(),
          last_modified_at: DateTime.t()
        }
end

defmodule Scheduling.EventRepository do
  @moduledoc "Returns all upcoming calendar events for the organisation."

  @spec fetch_quarter(Date.t()) :: [Scheduling.CalendarEvent.t()]
  def fetch_quarter(%Date{} = quarter_start) do
    now = DateTime.utc_now()

    Enum.flat_map(1..90, fn day ->
      date = Date.add(quarter_start, day - 1)

      Enum.map(1..80, fn slot ->
        starts = DateTime.new!(date, Time.add(~T[08:00:00], slot * 360, :second))
        ends = DateTime.add(starts, 3600, :second)

        %Scheduling.CalendarEvent{
          id: "evt_#{day}_#{slot}",
          title: "#{Enum.random(["Sync", "Review", "Planning", "Standup", "Demo"])} #{slot}",
          starts_at: starts,
          ends_at: ends,
          room_id: "ROOM-#{rem(slot, 20) + 1}",
          created_by: "emp_#{rem(slot, 500) + 1}",
          last_modified_at: DateTime.add(now, -:rand.uniform(86_400), :second),
          description:
            "Agenda: " <>
              Enum.join(
                Enum.map(1..5, fn i -> "Item #{i}: discuss Q#{rem(day, 4) + 1} roadmap item #{i}" end),
                ". "
              ),
          conference_link: "https://meet.example.com/#{:rand.uniform(999_999)}",
          tags: Enum.take(["product", "engineering", "design", "sales", "hr", "finance"], 3),
          recurrence:
            if rem(slot, 10) == 0 do
              %Scheduling.RecurrenceRule{
                freq: :weekly,
                interval: 1,
                until: Date.add(quarter_start, 90),
                by_day: ["MO", "WE"],
                exceptions: [Date.add(quarter_start, 14)]
              }
            end,
          attendees:
            Enum.map(1..12, fn a ->
              %Scheduling.Attendee{
                employee_id: "emp_#{rem(slot * a, 5000) + 1}",
                name: "Employee #{rem(slot * a, 5000) + 1}",
                email: "emp#{rem(slot * a, 5000) + 1}@corp.example.com",
                response: Enum.random([:accepted, :declined, :tentative, :pending]),
                is_organiser: a == 1
              }
            end)
        }
      end)
    end)
  end
end

defmodule Scheduling.ConsolidationWorker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, [], opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:bulk_events, quarter, events}, _state) do
    {:noreply, {quarter, events}}
  end
end

defmodule Scheduling.CalendarSync do
  @moduledoc """
  Loads all calendar events for a quarter and sends them to the
  consolidation worker for conflict detection and room utilisation analysis.
  """

  require Logger

  @spec push_bulk_update(pid(), Date.t()) :: :ok
  def push_bulk_update(worker_pid, %Date{} = quarter_start) do
    Logger.info("Loading calendar events for quarter starting #{quarter_start}...")

    events = Scheduling.EventRepository.fetch_quarter(quarter_start)

    Logger.info("Loaded #{length(events)} events. Pushing to consolidation worker...")

    send(worker_pid, {:bulk_events, quarter_start, events})

    Logger.info("Bulk calendar update dispatched.")
    :ok
  end
end
```
