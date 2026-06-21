# Code Smell Example 18

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `RouteTracker`, `DriverAssigner`, `DeliveryUpdater`, and `LogisticsReporter`
- **Affected functions:** `RouteTracker.start/1`, `DriverAssigner.assign/3`, `DeliveryUpdater.update_status/3`, `LogisticsReporter.daily_summary/1`
- **Short explanation:** The Agent holding live delivery route data is accessed directly from four separate logistics modules. State transitions (unassigned → in_transit → delivered) and data access are scattered, making it impossible to centrally enforce route lifecycle rules or detect conflicting updates.

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

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because RouteTracker directly writes to the Agent for
  # new route registration, while DriverAssigner, DeliveryUpdater, and LogisticsReporter
  # also directly access the same Agent, spreading responsibility across the system.
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
  # VALIDATION: SMELL END
end

defmodule DriverAssigner do
  @moduledoc """
  Assigns available drivers to unassigned delivery routes.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because DriverAssigner directly mutates the Agent to
  # assign a driver to a route, instead of going through a centralized RouteTracker API.
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
  # VALIDATION: SMELL END

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

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because DeliveryUpdater directly writes status
  # transitions into the Agent, introducing a third independent Agent mutation point.
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
  # VALIDATION: SMELL END
end

defmodule LogisticsReporter do
  @moduledoc """
  Produces daily delivery performance reports.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because LogisticsReporter directly reads the full Agent
  # state to compute reports, adding a fourth direct Agent dependency.
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
  # VALIDATION: SMELL END
end
```
