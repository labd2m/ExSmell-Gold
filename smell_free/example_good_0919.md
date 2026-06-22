```elixir
defmodule Ops.DeadProcessReaper do
  @moduledoc """
  Periodically scans registered named processes and removes stale Registry
  entries for processes that are no longer alive. This guards against
  Registry entries that persist after abnormal process termination without
  a proper unregistration step. The reaper is a low-priority background
  GenServer that runs on a configurable schedule.
  """

  use GenServer

  require Logger

  @type registry :: atom()
  @type reap_summary :: %{
          inspected: non_neg_integer(),
          reaped: non_neg_integer(),
          duration_ms: non_neg_integer()
        }

  @default_interval_ms :timer.minutes(5)

  @doc "Starts the dead process reaper for one or more registries."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Triggers an immediate reap cycle outside the normal schedule."
  @spec reap_now() :: {:ok, reap_summary()}
  def reap_now, do: GenServer.call(__MODULE__, :reap_now, :timer.minutes(2))

  @doc "Returns the configured list of monitored registries."
  @spec monitored_registries() :: [registry()]
  def monitored_registries, do: GenServer.call(__MODULE__, :registries)

  @impl GenServer
  def init(opts) do
    registries = Keyword.fetch!(opts, :registries)
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    Process.send_after(self(), :reap, interval)
    {:ok, %{registries: registries, interval: interval}}
  end

  @impl GenServer
  def handle_call(:reap_now, _from, state) do
    summary = do_reap(state.registries)
    {:reply, {:ok, summary}, state}
  end

  def handle_call(:registries, _from, state) do
    {:reply, state.registries, state}
  end

  @impl GenServer
  def handle_info(:reap, %{registries: registries, interval: interval} = state) do
    summary = do_reap(registries)
    if summary.reaped > 0 do
      Logger.info("[DeadProcessReaper] Reaped #{summary.reaped} stale entry(ies) in #{summary.duration_ms}ms")
    end
    Process.send_after(self(), :reap, interval)
    {:noreply, state}
  end

  defp do_reap(registries) do
    start_mono = System.monotonic_time(:millisecond)

    {inspected, reaped} =
      Enum.reduce(registries, {0, 0}, fn registry, {insp, reap} ->
        {i, r} = reap_registry(registry)
        {insp + i, reap + r}
      end)

    duration_ms = System.monotonic_time(:millisecond) - start_mono
    %{inspected: inspected, reaped: reaped, duration_ms: duration_ms}
  end

  defp reap_registry(registry) do
    entries = Registry.select(registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    inspected = length(entries)

    reaped =
      entries
      |> Enum.filter(fn {_key, pid, _value} -> not Process.alive?(pid) end)
      |> Enum.map(fn {key, pid, _value} ->
        Registry.unregister_match(registry, key, pid)
        1
      end)
      |> Enum.sum()

    {inspected, reaped}
  rescue
    _ -> {0, 0}
  end
end
```
