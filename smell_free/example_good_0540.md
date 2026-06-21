```elixir
defmodule Ops.AlertThrottler do
  @moduledoc """
  Prevents alert fatigue by throttling repeated identical alerts within
  a configurable suppression window. When an alert fires during an active
  suppression window, the call is acknowledged but no notification is sent.
  Alert suppression state is stored in the GenServer so no external store
  is required for single-node deployments.
  """

  use GenServer

  require Logger

  @type alert_key :: String.t()
  @type severity :: :info | :warning | :critical
  @type alert :: %{key: alert_key(), message: String.t(), severity: severity()}
  @type notify_fn :: (alert() -> :ok)
  @type fire_result :: {:ok, :notified} | {:ok, :suppressed}

  @default_window_ms :timer.minutes(30)

  @doc "Starts the alert throttler with a caller-supplied notification function."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Fires an alert. Delivers the notification via `notify_fn` on first occurrence
  within the suppression window. Subsequent identical alerts return
  `{:ok, :suppressed}` until the window expires.
  """
  @spec fire(alert()) :: fire_result()
  def fire(%{key: _, message: _, severity: _} = alert) do
    GenServer.call(__MODULE__, {:fire, alert})
  end

  @doc "Returns all currently suppressed alert keys."
  @spec suppressed_keys() :: [alert_key()]
  def suppressed_keys, do: GenServer.call(__MODULE__, :suppressed_keys)

  @doc "Clears the suppression record for `key`, allowing the next fire to notify."
  @spec clear(alert_key()) :: :ok
  def clear(key) when is_binary(key) do
    GenServer.cast(__MODULE__, {:clear, key})
  end

  @impl GenServer
  def init(opts) do
    notify_fn = Keyword.fetch!(opts, :notify_fn)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    {:ok, %{suppress_map: %{}, notify_fn: notify_fn, window_ms: window_ms}}
  end

  @impl GenServer
  def handle_call({:fire, %{key: key} = alert}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state.suppress_map, key) do
      %{until: until} when until > now ->
        {:reply, {:ok, :suppressed}, state}

      _ ->
        deliver_alert(state.notify_fn, alert)
        suppress_until = now + state.window_ms
        new_state = put_in(state, [:suppress_map, key], %{until: suppress_until, alert: alert})
        {:reply, {:ok, :notified}, new_state}
    end
  end

  def handle_call(:suppressed_keys, _from, state) do
    now = System.monotonic_time(:millisecond)
    keys = state.suppress_map |> Enum.filter(fn {_k, v} -> v.until > now end) |> Enum.map(&elem(&1, 0))
    {:reply, keys, state}
  end

  @impl GenServer
  def handle_cast({:clear, key}, state) do
    {:noreply, update_in(state, [:suppress_map], &Map.delete(&1, key))}
  end

  defp deliver_alert(notify_fn, alert) do
    Logger.info("[AlertThrottler] Delivering #{alert.severity} alert: #{alert.key}")
    notify_fn.(alert)
  rescue
    e -> Logger.error("[AlertThrottler] Notify function raised: #{Exception.message(e)}")
  end
end
```
