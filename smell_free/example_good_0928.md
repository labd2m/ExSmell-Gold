```elixir
defmodule Platform.ProcessMonitor do
  @moduledoc """
  A GenServer that periodically samples process and ETS table memory usage,
  emitting Telemetry events and logging warnings when thresholds are exceeded.

  Helps identify memory leaks, oversized mailboxes, and bloated ETS tables
  before they become production incidents.
  """

  use GenServer

  require Logger

  @type threshold_config :: %{
          process_heap_bytes: pos_integer(),
          process_mailbox: pos_integer(),
          ets_table_bytes: pos_integer()
        }

  @default_thresholds %{
    process_heap_bytes: 50 * 1024 * 1024,
    process_mailbox: 1_000,
    ets_table_bytes: 100 * 1024 * 1024
  }

  @default_interval_ms :timer.seconds(60)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns the most recent system-wide snapshot."
  @spec snapshot() :: map()
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    thresholds = Map.merge(@default_thresholds, Keyword.get(opts, :thresholds, %{}))
    schedule_sample(interval)

    {:ok, %{interval: interval, thresholds: thresholds, last_snapshot: nil}}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    {:reply, state.last_snapshot, state}
  end

  @impl GenServer
  def handle_info(:sample, state) do
    snapshot = collect_snapshot(state.thresholds)
    schedule_sample(state.interval)
    {:noreply, %{state | last_snapshot: snapshot}}
  end

  defp collect_snapshot(thresholds) do
    processes = sample_processes(thresholds)
    tables = sample_ets_tables(thresholds)

    snapshot = %{
      sampled_at: DateTime.utc_now(),
      process_count: length(:erlang.processes()),
      oversized_processes: Enum.filter(processes, & &1.exceeds_threshold),
      ets_table_count: length(:ets.all()),
      oversized_tables: Enum.filter(tables, & &1.exceeds_threshold),
      total_process_memory_mb: total_process_memory_mb(),
      total_ets_memory_mb: total_ets_memory_mb()
    }

    emit_telemetry(snapshot)
    log_warnings(snapshot)
    snapshot
  end

  defp sample_processes(thresholds) do
    :erlang.processes()
    |> Enum.map(fn pid ->
      info = Process.info(pid, [:heap_size, :message_queue_len, :registered_name, :current_function])

      heap_bytes = (info[:heap_size] || 0) * :erlang.system_info(:wordsize)
      mailbox = info[:message_queue_len] || 0
      exceeds = heap_bytes > thresholds.process_heap_bytes or mailbox > thresholds.process_mailbox

      %{
        pid: pid,
        name: info[:registered_name],
        heap_mb: Float.round(heap_bytes / 1_048_576, 2),
        mailbox_size: mailbox,
        current_function: info[:current_function],
        exceeds_threshold: exceeds
      }
    end)
  end

  defp sample_ets_tables(thresholds) do
    :ets.all()
    |> Enum.map(fn table ->
      info = :ets.info(table)
      bytes = (info[:memory] || 0) * :erlang.system_info(:wordsize)
      exceeds = bytes > thresholds.ets_table_bytes

      %{
        table: table,
        name: info[:name],
        size: info[:size],
        memory_mb: Float.round(bytes / 1_048_576, 2),
        type: info[:type],
        exceeds_threshold: exceeds
      }
    end)
  end

  defp emit_telemetry(%{process_count: pc, total_process_memory_mb: pm, total_ets_memory_mb: em}) do
    :telemetry.execute(
      [:platform, :process_monitor, :sample],
      %{process_count: pc, process_memory_mb: pm, ets_memory_mb: em},
      %{}
    )
  end

  defp log_warnings(%{oversized_processes: procs, oversized_tables: tables}) do
    Enum.each(procs, fn p ->
      Logger.warning("[ProcessMonitor] Oversized process", pid: inspect(p.pid), heap_mb: p.heap_mb, mailbox: p.mailbox_size)
    end)

    Enum.each(tables, fn t ->
      Logger.warning("[ProcessMonitor] Oversized ETS table", table: t.name, memory_mb: t.memory_mb, rows: t.size)
    end)
  end

  defp total_process_memory_mb do
    :erlang.memory(:processes_used) |> Kernel./(1_048_576) |> Float.round(2)
  end

  defp total_ets_memory_mb do
    :erlang.memory(:ets) |> Kernel./(1_048_576) |> Float.round(2)
  end

  defp schedule_sample(interval), do: Process.send_after(self(), :sample, interval)
end
```
