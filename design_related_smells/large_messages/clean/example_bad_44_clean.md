```elixir
defmodule ShiftBroadcaster do
  use GenServer
  require Logger

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{published: 0}, opts)
  end

  def published_count(pid), do: GenServer.call(pid, :published_count)

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:published_count, _from, state) do
    {:reply, state.published, state}
  end

  @impl true
  def handle_cast({:publish_schedule, site_id, schedule}, state) do
    Logger.info("ShiftBroadcaster: publishing #{length(schedule)} shifts for site=#{site_id}")

    Enum.each(schedule, fn shift ->
      notify_employee(shift)
    end)

    Logger.info("ShiftBroadcaster: done publishing for site=#{site_id}")
    {:noreply, %{state | published: state.published + length(schedule)}}
  end

  @impl true
  def handle_cast(_msg, state), do: {:noreply, state}

  defp notify_employee(_shift), do: :ok
end

defmodule ShiftPublisher do
  require Logger

  @doc """
  Computes the upcoming four-week shift schedule for all employees at a
  given site and forwards the full schedule to the broadcaster, which is
  responsible for delivering individual shift notifications.
  """
  def publish(broadcaster_pid, site_id) do
    Logger.info("ShiftPublisher: building 4-week schedule for site=#{site_id}")

    schedule = build_schedule(site_id)

    Logger.info("ShiftPublisher: #{length(schedule)} shifts ready — sending to broadcaster")

    GenServer.cast(broadcaster_pid, {:publish_schedule, site_id, schedule})

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers — simulate generating a large workforce schedule
  # ---------------------------------------------------------------------------

  defp build_schedule(site_id) do
    employees = Enum.map(1..3_000, fn n -> "EMP-#{site_id}-#{n}" end)
    start_date = ~D[2024-07-01]

    for employee_id <- employees,
        day_offset <- 0..27 do
      shift_date = Date.add(start_date, day_offset)
      start_hour = Enum.random([6, 8, 10, 14, 22])

      %{
        shift_id: "SHIFT-#{site_id}-#{employee_id}-#{Date.to_string(shift_date)}",
        site_id: site_id,
        employee_id: employee_id,
        date: shift_date,
        start_time: Time.new!(start_hour, 0, 0),
        end_time: Time.new!(rem(start_hour + 8, 24), 0, 0),
        role: Enum.random([:cashier, :stock, :supervisor, :security, :cleaning]),
        department: Enum.random(["grocery", "bakery", "produce", "electronics"]),
        breaks: [
          %{start: Time.new!(start_hour + 2, 0, 0), duration_min: 15},
          %{start: Time.new!(start_hour + 5, 0, 0), duration_min: 30}
        ],
        compliance: %{
          min_rest_hours: 11,
          max_weekly_hours: 48,
          requires_certification: false
        },
        published_at: DateTime.utc_now()
      }
    end
  end
end
```
