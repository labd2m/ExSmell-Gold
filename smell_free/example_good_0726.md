```elixir
defmodule Platform.CrashReporter do
  @moduledoc """
  A GenServer that attaches to Telemetry and monitors process crashes,
  aggregating them into a structured crash log with rate-limiting to
  prevent alert storms during incident cascades.

  Crash events are delivered to a configurable handler (Slack, email, PagerDuty)
  with deduplication: repeated identical crashes within a cooldown window
  are counted but not re-alerted.
  """

  use GenServer

  require Logger

  @type crash_key :: {module(), atom()}
  @type crash_record :: %{
          module: module(),
          reason: term(),
          count: pos_integer(),
          first_seen: DateTime.t(),
          last_seen: DateTime.t()
        }

  @default_cooldown_ms :timer.minutes(5)
  @sweep_interval_ms :timer.minutes(10)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns a map of all active crash records."
  @spec active_crashes() :: %{optional(crash_key()) => crash_record()}
  def active_crashes, do: GenServer.call(__MODULE__, :active_crashes)

  @doc "Clears all tracked crash records."
  @spec clear() :: :ok
  def clear, do: GenServer.cast(__MODULE__, :clear)

  @impl GenServer
  def init(opts) do
    cooldown_ms = Keyword.get(opts, :cooldown_ms, @default_cooldown_ms)
    handler = Keyword.get(opts, :handler)

    attach_telemetry()
    schedule_sweep()

    {:ok, %{crashes: %{}, cooldown_ms: cooldown_ms, handler: handler}}
  end

  @impl GenServer
  def handle_call(:active_crashes, _from, state) do
    {:reply, state.crashes, state}
  end

  @impl GenServer
  def handle_cast(:clear, state) do
    {:noreply, %{state | crashes: %{}}}
  end

  @impl GenServer
  def handle_cast({:crash, module, reason, stacktrace}, state) do
    key = crash_key(module, reason)
    now = DateTime.utc_now()

    {new_crashes, should_alert} = update_crash_record(state.crashes, key, module, reason, now, state.cooldown_ms)

    if should_alert && state.handler do
      record = Map.fetch!(new_crashes, key)
      deliver_alert(state.handler, record, stacktrace)
    end

    {:noreply, %{state | crashes: new_crashes}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    cutoff = DateTime.add(DateTime.utc_now(), -:timer.hours(1), :millisecond)
    fresh = Map.reject(state.crashes, fn {_, r} -> DateTime.before?(r.last_seen, cutoff) end)
    schedule_sweep()
    {:noreply, %{state | crashes: fresh}}
  end

  defp attach_telemetry do
    :telemetry.attach(
      "crash_reporter",
      [:platform, :process, :crash],
      fn _event, _measurements, %{module: mod, reason: reason, stacktrace: st}, _config ->
        GenServer.cast(__MODULE__, {:crash, mod, reason, st})
      end,
      nil
    )
  end

  defp update_crash_record(crashes, key, module, reason, now, cooldown_ms) do
    case Map.get(crashes, key) do
      nil ->
        record = %{module: module, reason: reason, count: 1, first_seen: now, last_seen: now, alerted_at: now}
        {Map.put(crashes, key, record), true}

      existing ->
        updated = %{existing | count: existing.count + 1, last_seen: now}
        age_ms = DateTime.diff(now, existing.alerted_at, :millisecond)
        should_alert = age_ms >= cooldown_ms
        alertable = if should_alert, do: %{updated | alerted_at: now}, else: updated
        {Map.put(crashes, key, alertable), should_alert}
    end
  end

  defp deliver_alert(handler, %{module: mod, reason: reason, count: count}, stacktrace) do
    message = %{
      title: "Process crash: #{inspect(mod)}",
      reason: inspect(reason),
      count: count,
      stacktrace: Exception.format_stacktrace(stacktrace)
    }

    try do
      handler.(message)
    rescue
      error -> Logger.error("[CrashReporter] Alert delivery failed", error: inspect(error))
    end
  end

  defp crash_key(module, reason) do
    {module, :erlang.phash2(reason)}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
```
