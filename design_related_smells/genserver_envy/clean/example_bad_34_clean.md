```elixir
defmodule MyApp.LoadBalancerTask do
  @moduledoc """
  Round-robin load balancer for distributing work to a pool of
  worker nodes, with health awareness and graceful drain support.
  """

  alias MyApp.{HealthChecker, AlertService, MetricsCollector}
  alias MyApp.Cluster.{Backend, RoutingDecision}

  @health_check_interval_ms 10_000
  @unhealthy_threshold 3

  def start_balancer(backends) do
    Task.start_link(fn ->
      indexed =
        backends
        |> Enum.with_index()
        |> Enum.into(%{}, fn {b, i} -> {b.id, %{b | index: i, failures: 0}} end)

      state = %{
        backends: indexed,
        current_idx: 0,
        total_routed: 0,
        total_failed: 0
      }

      schedule_health_check()
      balancer_loop(state)
    end)
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval_ms)
  end

  defp balancer_loop(state) do
    receive do
      {:route, from} ->
        eligible =
          state.backends
          |> Map.values()
          |> Enum.filter(&(&1.status in [:healthy, :degraded] and not &1.draining))
          |> Enum.sort_by(& &1.index)

        case eligible do
          [] ->
            send(from, {:error, :no_backends_available})
            balancer_loop(%{state | total_failed: state.total_failed + 1})

          backends ->
            idx = rem(state.current_idx, length(backends))
            chosen = Enum.at(backends, idx)
            decision = %RoutingDecision{backend_id: chosen.id, routed_at: DateTime.utc_now()}
            MetricsCollector.increment(:requests_routed, backend: chosen.id)
            send(from, {:ok, decision})

            balancer_loop(%{
              state
              | current_idx: state.current_idx + 1,
                total_routed: state.total_routed + 1
            })
        end

      {:register, from, %Backend{} = backend} ->
        new_backends = Map.put(state.backends, backend.id, %{backend | failures: 0})
        send(from, :ok)
        balancer_loop(%{state | backends: new_backends})

      {:deregister, from, backend_id} ->
        new_backends = Map.delete(state.backends, backend_id)
        send(from, :ok)
        balancer_loop(%{state | backends: new_backends})

      {:drain, from, backend_id} ->
        case Map.fetch(state.backends, backend_id) do
          :error ->
            send(from, {:error, :not_found})
            balancer_loop(state)

          {:ok, backend} ->
            updated = %{backend | draining: true}
            send(from, :ok)
            balancer_loop(%{state | backends: Map.put(state.backends, backend_id, updated)})
        end

      {:undrain, from, backend_id} ->
        case Map.fetch(state.backends, backend_id) do
          :error ->
            send(from, {:error, :not_found})
            balancer_loop(state)

          {:ok, backend} ->
            updated = %{backend | draining: false}
            send(from, :ok)
            balancer_loop(%{state | backends: Map.put(state.backends, backend_id, updated)})
        end

      :health_check ->
        new_backends =
          Map.new(state.backends, fn {id, backend} ->
            case HealthChecker.ping(backend.address) do
              :ok ->
                {id, %{backend | status: :healthy, failures: 0}}

              :error ->
                new_failures = backend.failures + 1

                new_status =
                  cond do
                    new_failures >= @unhealthy_threshold -> :unhealthy
                    new_failures > 0 -> :degraded
                    true -> :healthy
                  end

                if new_status == :unhealthy and backend.status != :unhealthy do
                  AlertService.notify(:backend_unhealthy, %{backend_id: id})
                end

                {id, %{backend | failures: new_failures, status: new_status}}
            end
          end)

        schedule_health_check()
        balancer_loop(%{state | backends: new_backends})

      {:get_stats, from} ->
        by_status =
          state.backends
          |> Map.values()
          |> Enum.group_by(& &1.status)
          |> Map.new(fn {status, list} -> {status, length(list)} end)

        send(from, {:ok, Map.merge(%{total_routed: state.total_routed, total_failed: state.total_failed}, by_status)})
        balancer_loop(state)

      :stop ->
        :ok
    end
  end

  def route(pid) do
    send(pid, {:route, self()})

    receive do
      {:ok, decision} -> {:ok, decision}
      {:error, reason} -> {:error, reason}
    after
      2_000 -> {:error, :timeout}
    end
  end

  def drain(pid, backend_id) do
    send(pid, {:drain, self(), backend_id})

    receive do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    after
      3_000 -> {:error, :timeout}
    end
  end

  def get_stats(pid) do
    send(pid, {:get_stats, self()})

    receive do
      {:ok, stats} -> {:ok, stats}
    after
      3_000 -> {:error, :timeout}
    end
  end
end
```
