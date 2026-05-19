```elixir
defmodule Logistics.RouteTracker do
  @moduledoc """
  Tracks the real-time position of delivery vehicles along a route.
  """

  def start_route(route_id, waypoints) do
    Agent.start_link(fn ->
      %{
        route_id: route_id,
        waypoints: waypoints,
        current_index: 0,
        positions: [],
        delays: [],
        completed: false
      }
    end)
  end

  def update_position(pid, coords, timestamp) do
    Agent.update(pid, fn state ->
      position_entry = %{coords: coords, recorded_at: timestamp}
      %{state | positions: [position_entry | state.positions]}
    end)
  end

  def advance_waypoint(pid) do
    Agent.update(pid, fn state ->
      next_index = min(state.current_index + 1, length(state.waypoints) - 1)
      completed = next_index == length(state.waypoints) - 1
      %{state | current_index: next_index, completed: completed}
    end)
  end

  def current_waypoint(pid) do
    Agent.get(pid, fn state ->
      Enum.at(state.waypoints, state.current_index)
    end)
  end
end

defmodule Logistics.RouteOptimizer do
  @moduledoc """
  Recalculates optimal routes based on current conditions.
  """

  def recalculate(pid, new_waypoints) do
    Agent.update(pid, fn state ->
      %{state | waypoints: new_waypoints, current_index: 0}
    end)
  end

  def remaining_distance(pid) do
    Agent.get(pid, fn state ->
      remaining_waypoints = Enum.drop(state.waypoints, state.current_index)
      Enum.reduce_while(remaining_waypoints, {0.0, nil}, fn wp, {dist, prev} ->
        if prev == nil do
          {:cont, {dist, wp}}
        else
          segment_dist = haversine(prev.lat, prev.lon, wp.lat, wp.lon)
          {:cont, {dist + segment_dist, wp}}
        end
      end)
      |> elem(0)
    end)
  end

  defp haversine(lat1, lon1, lat2, lon2) do
    r = 6_371_000
    phi1 = lat1 * :math.pi() / 180
    phi2 = lat2 * :math.pi() / 180
    dphi = (lat2 - lat1) * :math.pi() / 180
    dlambda = (lon2 - lon1) * :math.pi() / 180
    a = :math.sin(dphi / 2) ** 2 + :math.cos(phi1) * :math.cos(phi2) * :math.sin(dlambda / 2) ** 2
    2 * r * :math.asin(:math.sqrt(a))
  end
end

defmodule Logistics.RouteReporter do
  @moduledoc """
  Generates progress summaries and ETAs for routes.
  """

  def progress_summary(pid) do
    Agent.get(pid, fn state ->
      total = length(state.waypoints)
      completed = state.current_index
      pct = if total == 0, do: 0.0, else: completed / total * 100.0

      %{
        route_id: state.route_id,
        total_waypoints: total,
        completed_waypoints: completed,
        progress_pct: Float.round(pct, 2),
        is_complete: state.completed
      }
    end)
  end

  def position_history(pid) do
    Agent.get(pid, fn state -> Enum.reverse(state.positions) end)
  end
end

defmodule Logistics.RouteAlerter do
  @moduledoc """
  Monitors route progress and fires delay alerts.
  """

  def check_delays(pid, expected_arrival) do
    state = Agent.get(pid, fn s -> s end)

    if state.completed do
      {:ok, :no_delays}
    else
      now = DateTime.utc_now()
      if DateTime.compare(now, expected_arrival) == :gt do
        delay_minutes = div(DateTime.diff(now, expected_arrival, :second), 60)
        IO.puts("Route #{state.route_id} is delayed by #{delay_minutes} minutes")
        {:delayed, delay_minutes}
      else
        {:ok, :on_time}
      end
    end
  end

  def record_delay(pid, reason) do
    Agent.update(pid, fn state ->
      delay = %{reason: reason, recorded_at: DateTime.utc_now()}
      %{state | delays: [delay | state.delays]}
    end)
  end
end
```
