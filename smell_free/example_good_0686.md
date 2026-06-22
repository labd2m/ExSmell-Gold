```elixir
defmodule Inventory.StockAlertSupervisor do
  @moduledoc """
  Supervises per-SKU stock alert monitors. Each monitor watches a single
  SKU and fires a notification when on-hand quantity crosses a configurable
  low-stock threshold. Monitors are started on demand and terminate
  normally once the alert has been dispatched, freeing resources until
  the next restock cycle triggers a fresh monitor.
  """

  use DynamicSupervisor

  alias Inventory.StockAlertMonitor

  @type sku :: String.t()
  @type threshold :: pos_integer()

  @doc "Starts the supervisor linked to the calling process."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a monitor for `sku`. Returns `{:error, :already_monitoring}`
  when an active monitor for that SKU already exists.
  """
  @spec watch(sku(), threshold()) :: {:ok, pid()} | {:error, :already_monitoring}
  def watch(sku, threshold)
      when is_binary(sku) and is_integer(threshold) and threshold > 0 do
    spec = {StockAlertMonitor, sku: sku, threshold: threshold}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, _}} -> {:error, :already_monitoring}
      {:error, _} -> {:error, :already_monitoring}
    end
  end

  @doc "Stops the monitor for `sku` if one is running."
  @spec unwatch(sku()) :: :ok
  def unwatch(sku) when is_binary(sku) do
    case Registry.lookup(Inventory.AlertRegistry, sku) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> :ok
    end

    :ok
  end

  @doc "Returns true when `sku` has an active monitor."
  @spec watching?(sku()) :: boolean()
  def watching?(sku) when is_binary(sku) do
    Registry.lookup(Inventory.AlertRegistry, sku) != []
  end

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end

defmodule Inventory.StockAlertMonitor do
  @moduledoc """
  Polls the inventory store for a single SKU's on-hand quantity and
  dispatches a low-stock alert notification when the quantity falls
  at or below the configured threshold. Terminates normally after
  firing to avoid repeated alerts until the supervisor re-registers it.
  """

  use GenServer

  require Logger

  alias Inventory.StockLedger
  alias Notifications.Dispatcher, as: Notify

  @poll_interval_ms :timer.minutes(5)

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    sku = Keyword.fetch!(opts, :sku)
    GenServer.start_link(__MODULE__, opts, name: via(sku))
  end

  @impl GenServer
  def init(opts) do
    Process.send_after(self(), :poll, @poll_interval_ms)
    {:ok, %{sku: Keyword.fetch!(opts, :sku), threshold: Keyword.fetch!(opts, :threshold)}}
  end

  @impl GenServer
  def handle_info(:poll, %{sku: sku, threshold: threshold} = state) do
    case StockLedger.on_hand(sku) do
      {:ok, qty} when qty <= threshold ->
        Logger.info("[StockAlertMonitor] Low stock for #{sku}: #{qty} <= #{threshold}")
        dispatch_alert(sku, qty, threshold)
        {:stop, :normal, state}

      {:ok, _qty} ->
        Process.send_after(self(), :poll, @poll_interval_ms)
        {:noreply, state}

      {:error, :unknown_sku} ->
        Logger.warning("[StockAlertMonitor] Unknown SKU #{sku}, stopping monitor")
        {:stop, :normal, state}
    end
  end

  defp dispatch_alert(sku, qty, threshold) do
    Notify.dispatch(%{
      type: :low_stock_alert,
      recipient_id: "ops-team",
      payload: %{sku: sku, on_hand: qty, threshold: threshold}
    })
  end

  defp via(sku), do: {:via, Registry, {Inventory.AlertRegistry, sku}}
end
```
