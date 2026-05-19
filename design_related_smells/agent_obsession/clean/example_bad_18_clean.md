```elixir
defmodule RouteTracker do
  @moduledoc """
  Initializes and provides access to the live delivery route Agent.
  """

  def start(routes \\ []) do
    initial =
      routes
      |> Enum.map(fn r ->
        {r.id, Map.merge(r, %{status: :unassigned, driver_id: nil, events: []})}
      end)
      |> Map.new()

    {:ok, pid} = Agent.start_link(fn -> initial end)
    pid
  end

  def register(pid, route) do
    entry = Map.merge(route, %{status: :unassigned, driver_id: nil, events: []})

    Agent.update(pid, fn routes -> Map.put(routes, route.id, entry) end)
    :ok
  end

  def fetch(pid, route_id) do
    Agent.get(pid, fn routes -> Map.fetch(routes, route_id) end)
  end

  def all(pid) do
    Agent.get(pid, fn routes -> Map.values(routes) end)
  end
end

defmodule DriverAssigner do
  @moduledoc """
  Assigns available drivers to unassigned delivery routes.
  """

  def assign(pid, route_id, driver_id) do
    Agent.get_and_update(pid, fn routes ->
      case Map.fetch(routes, route_id) do
        {:ok, %{status: :unassigned} = route} ->
          updated = %{route | status: :assigned, driver_id: driver_id}
          event = %{type: :assigned, driver_id: driver_id, at: DateTime.utc_now()}
          updated_with_event = %{updated | events: [event | updated.events]}
          {:ok, Map.put(routes, route_id, updated_with_event)}

        {:ok, %{status: status}} ->
          {{:error, {:wrong_status, status}}, routes}

        :error ->
          {{:error, :not_found}, routes}
      end
    end)
  end

  def available_routes(pid) do
    Agent.get(pid, fn routes ->
      routes |> Map.values() |> Enum.filter(&(&1.status == :unassigned))
    end)
  end
end

defmodule DeliveryUpdater do
  @moduledoc """
  Processes real-time GPS and delivery status updates.
  """

  @valid_transitions %{
    assigned: [:in_transit],
    in_transit: [:delivered, :failed]
  }

  def update_status(pid, route_id, new_status) do
    Agent.get_and_update(pid, fn routes ->
      case Map.fetch(routes, route_id) do
        {:ok, route} ->
          allowed = Map.get(@valid_transitions, route.status, [])

          if new_status in allowed do
            event = %{type: :status_change, to: new_status, at: DateTime.utc_now()}
            updated = %{route | status: new_status, events: [event | route.events]}
            {:ok, Map.put(routes, route_id, updated)}
          else
            {{:error, {:invalid_transition, route.status, new_status}}, routes}
          end

        :error ->
          {{:error, :not_found}, routes}
      end
    end)
  end

  def append_gps(pid, route_id, coords) do
    Agent.update(pid, fn routes ->
      Map.update(routes, route_id, %{}, fn route ->
        gps = Map.get(route, :gps_trail, [])
        Map.put(route, :gps_trail, [coords | gps])
      end)
    end)
  end
end

defmodule LogisticsReporter do
  @moduledoc """
  Produces daily delivery performance reports.
  """

  def daily_summary(pid) do
    Agent.get(pid, fn routes ->
      all = Map.values(routes)

      %{
        total: length(all),
        unassigned: Enum.count(all, &(&1.status == :unassigned)),
        assigned: Enum.count(all, &(&1.status == :assigned)),
        in_transit: Enum.count(all, &(&1.status == :in_transit)),
        delivered: Enum.count(all, &(&1.status == :delivered)),
        failed: Enum.count(all, &(&1.status == :failed))
      }
    end)
  end

  def failed_routes(pid) do
    Agent.get(pid, fn routes ->
      routes |> Map.values() |> Enum.filter(&(&1.status == :failed))
    end)
  end
end
```
