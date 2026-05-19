```elixir
defmodule MyApp.ConnectionPoolMonitorTask do
  @moduledoc """
  Monitors a pool of database connections, tracks health, enforces
  checkout limits, and recycles stale or broken connections.
  """

  alias MyApp.{DBDriver, AlertService, MetricsCollector}
  alias MyApp.Pool.{Connection, CheckoutRecord}

  @health_check_interval_ms 15_000
  @max_idle_seconds 300
  @checkout_timeout_seconds 30

  def start_monitor(config) do
    Task.start_link(fn ->
      conns =
        Enum.map(1..config.pool_size, fn i ->
          {:ok, conn} = DBDriver.connect(config.dsn)
          %Connection{id: i, conn: conn, status: :idle, created_at: DateTime.utc_now()}
        end)

      state = %{
        config: config,
        connections: Enum.into(conns, %{}, &{&1.id, &1}),
        checkouts: %{},
        health_failures: 0
      }

      schedule_health_check()
      monitor_loop(state)
    end)
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval_ms)
  end

  defp monitor_loop(state) do
    receive do
      {:checkout, from, caller_ref} ->
        idle = Enum.find(state.connections, fn {_id, c} -> c.status == :idle end)

        case idle do
          nil ->
            send(from, {:error, :pool_exhausted})
            monitor_loop(state)

          {id, conn} ->
            record = %CheckoutRecord{
              conn_id: id,
              caller_ref: caller_ref,
              checked_out_at: DateTime.utc_now(),
              expires_at: DateTime.add(DateTime.utc_now(), @checkout_timeout_seconds, :second)
            }

            updated_conn = %{conn | status: :in_use}
            new_conns = Map.put(state.connections, id, updated_conn)
            new_checkouts = Map.put(state.checkouts, caller_ref, record)

            MetricsCollector.gauge(:pool_idle, map_size(new_conns) - map_size(new_checkouts))
            send(from, {:ok, conn.conn, id})
            monitor_loop(%{state | connections: new_conns, checkouts: new_checkouts})
        end

      {:checkin, conn_id, caller_ref} ->
        new_checkouts = Map.delete(state.checkouts, caller_ref)
        updated_conn = Map.update!(state.connections, conn_id, fn c ->
          %{c | status: :idle, last_used_at: DateTime.utc_now()}
        end)

        MetricsCollector.gauge(:pool_idle, map_size(updated_conn) - map_size(new_checkouts))
        monitor_loop(%{state | connections: updated_conn, checkouts: new_checkouts})

      :health_check ->
        now = DateTime.utc_now()

        {healthy, sick} =
          state.connections
          |> Enum.reject(fn {id, _} -> Map.has_key?(state.checkouts, id) end)
          |> Enum.split_with(fn {_id, conn} ->
            DBDriver.ping(conn.conn) == :ok
          end)

        recycled =
          Enum.map(sick, fn {id, old_conn} ->
            DBDriver.disconnect(old_conn.conn)
            {:ok, new_raw} = DBDriver.connect(state.config.dsn)
            new_conn = %{old_conn | conn: new_raw, status: :idle, created_at: now, health_failures: 0}
            {id, new_conn}
          end)

        stale_timeout =
          Enum.map(healthy, fn {id, conn} ->
            last = conn.last_used_at || conn.created_at
            idle_s = DateTime.diff(now, last, :second)

            if idle_s > @max_idle_seconds do
              DBDriver.disconnect(conn.conn)
              {:ok, new_raw} = DBDriver.connect(state.config.dsn)
              {id, %{conn | conn: new_raw, created_at: now}}
            else
              {id, conn}
            end
          end)

        if length(sick) > 0 do
          AlertService.notify(:pool_health_degraded, %{recycled: length(sick)})
        end

        merged = Map.merge(state.connections, Map.new(recycled ++ stale_timeout))
        schedule_health_check()
        monitor_loop(%{state | connections: merged})

      {:sweep_expired_checkouts} ->
        now = DateTime.utc_now()

        {expired, active} =
          Enum.split_with(state.checkouts, fn {_ref, record} ->
            DateTime.compare(record.expires_at, now) == :lt
          end)

        Enum.each(expired, fn {_ref, record} ->
          AlertService.notify(:checkout_timeout, %{conn_id: record.conn_id})
        end)

        freed_conns =
          Enum.reduce(expired, state.connections, fn {_ref, record}, acc ->
            Map.update!(acc, record.conn_id, &%{&1 | status: :idle})
          end)

        monitor_loop(%{state | connections: freed_conns, checkouts: Map.new(active)})

      {:get_stats, from} ->
        stats = %{
          total: map_size(state.connections),
          idle: Enum.count(state.connections, fn {_, c} -> c.status == :idle end),
          in_use: map_size(state.checkouts)
        }
        send(from, {:ok, stats})
        monitor_loop(state)

      :stop ->
        Enum.each(state.connections, fn {_, c} -> DBDriver.disconnect(c.conn) end)
        :ok
    end
  end

  def checkout(pid, caller_ref) do
    send(pid, {:checkout, self(), caller_ref})

    receive do
      {:ok, conn, id} -> {:ok, conn, id}
      {:error, reason} -> {:error, reason}
    after
      5_000 -> {:error, :timeout}
    end
  end

  def checkin(pid, conn_id, caller_ref) do
    send(pid, {:checkin, conn_id, caller_ref})
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
