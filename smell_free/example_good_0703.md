# File: `example_good_703.md`

```elixir
defmodule Commerce.AbandonedCartRecovery do
  @moduledoc """
  GenServer that detects abandoned shopping carts and triggers recovery
  notifications through a configurable handler.

  A cart is considered abandoned when it contains at least one item and
  has not been updated within the idle threshold. Carts already notified
  are tracked to prevent duplicate recovery emails within the same window.
  """

  use GenServer

  require Logger

  @default_idle_threshold_minutes 60
  @default_scan_interval_ms 300_000

  @type cart_key :: String.t()
  @type recovery_handler :: module()

  @type opts :: [
          cart_store: module(),
          handler: recovery_handler(),
          idle_threshold_minutes: pos_integer(),
          scan_interval_ms: pos_integer()
        ]

  @doc false
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns statistics for the current recovery session.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Marks a cart as recovered (e.g. the user completed checkout) so it
  will not receive further recovery notifications.
  """
  @spec mark_recovered(cart_key()) :: :ok
  def mark_recovered(cart_key) when is_binary(cart_key) do
    GenServer.cast(__MODULE__, {:mark_recovered, cart_key})
  end

  @impl GenServer
  def init(opts) do
    cart_store = Keyword.fetch!(opts, :cart_store)
    handler = Keyword.fetch!(opts, :handler)
    idle_minutes = Keyword.get(opts, :idle_threshold_minutes, @default_idle_threshold_minutes)
    scan_interval_ms = Keyword.get(opts, :scan_interval_ms, @default_scan_interval_ms)

    schedule_scan(scan_interval_ms)

    {:ok, %{
      cart_store: cart_store,
      handler: handler,
      idle_threshold_minutes: idle_minutes,
      scan_interval_ms: scan_interval_ms,
      notified: MapSet.new(),
      recovered: MapSet.new(),
      total_detected: 0,
      total_notified: 0
    }}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    stats = %{
      total_detected: state.total_detected,
      total_notified: state.total_notified,
      currently_notified: MapSet.size(state.notified),
      recovered: MapSet.size(state.recovered)
    }

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_cast({:mark_recovered, cart_key}, state) do
    new_state = %{state |
      recovered: MapSet.put(state.recovered, cart_key),
      notified: MapSet.delete(state.notified, cart_key)
    }

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:scan, state) do
    new_state = run_scan(state)
    schedule_scan(state.scan_interval_ms)
    {:noreply, new_state}
  end

  defp run_scan(state) do
    cutoff = DateTime.add(DateTime.utc_now(), -state.idle_threshold_minutes * 60, :second)

    abandoned_carts = state.cart_store.list_idle_since(cutoff)

    eligible =
      Enum.reject(abandoned_carts, fn cart ->
        MapSet.member?(state.recovered, cart.key) or
          MapSet.member?(state.notified, cart.key) or
          map_size(cart.items) == 0
      end)

    {notified_count, updated_notified} =
      Enum.reduce(eligible, {0, state.notified}, fn cart, {count, notified_set} ->
        case notify_cart(cart, state.handler) do
          :ok ->
            {count + 1, MapSet.put(notified_set, cart.key)}

          {:error, reason} ->
            Logger.warning("Failed to send recovery for cart #{cart.key}: #{inspect(reason)}")
            {count, notified_set}
        end
      end)

    %{state |
      notified: updated_notified,
      total_detected: state.total_detected + length(eligible),
      total_notified: state.total_notified + notified_count
    }
  end

  defp notify_cart(cart, handler) do
    case handler.send_recovery(cart) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp schedule_scan(interval_ms) do
    Process.send_after(self(), :scan, interval_ms)
  end
end
```
