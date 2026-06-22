```elixir
defmodule Inventory.ReorderMonitor do
  @moduledoc """
  Supervised GenServer that periodically scans stock levels and raises
  reorder alerts when quantities fall below configured thresholds.

  Alert delivery is delegated to a pluggable notifier, enabling different
  channels (email, Slack, PagerDuty) per deployment without changing
  the monitor logic.
  """

  use GenServer

  require Logger

  alias Inventory.ReorderMonitor.{ThresholdStore, StockReader, Alert, Notifier}

  @scan_interval_ms 60_000

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Registers a reorder threshold for a SKU.
  """
  @spec set_threshold(String.t(), non_neg_integer(), keyword()) :: :ok
  def set_threshold(sku, quantity, opts \\ [])
      when is_binary(sku) and is_integer(quantity) and quantity >= 0 do
    notifier = Keyword.get(opts, :notifier, Notifier.default())
    GenServer.cast(__MODULE__, {:set_threshold, sku, quantity, notifier})
  end

  @doc """
  Removes the threshold for a SKU, stopping future alerts for it.
  """
  @spec remove_threshold(String.t()) :: :ok
  def remove_threshold(sku) when is_binary(sku) do
    GenServer.cast(__MODULE__, {:remove_threshold, sku})
  end

  @doc """
  Triggers an immediate scan outside the normal schedule.
  """
  @spec scan_now() :: :ok
  def scan_now, do: GenServer.cast(__MODULE__, :scan_now)

  @impl GenServer
  def init(opts) do
    reader = Keyword.get(opts, :stock_reader, StockReader.default())
    schedule_scan()
    {:ok, %{thresholds: ThresholdStore.new(), reader: reader}}
  end

  @impl GenServer
  def handle_cast({:set_threshold, sku, qty, notifier}, state) do
    updated = ThresholdStore.put(state.thresholds, sku, qty, notifier)
    {:noreply, %{state | thresholds: updated}}
  end

  def handle_cast({:remove_threshold, sku}, state) do
    updated = ThresholdStore.delete(state.thresholds, sku)
    {:noreply, %{state | thresholds: updated}}
  end

  def handle_cast(:scan_now, state) do
    perform_scan(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:scan, state) do
    perform_scan(state)
    schedule_scan()
    {:noreply, state}
  end

  defp perform_scan(%{thresholds: thresholds, reader: reader}) do
    skus = ThresholdStore.all_skus(thresholds)

    skus
    |> StockReader.fetch_levels(reader)
    |> Enum.each(fn {sku, level} ->
      check_and_alert(sku, level, thresholds)
    end)
  end

  defp check_and_alert(sku, current_level, thresholds) do
    case ThresholdStore.fetch(thresholds, sku) do
      {:ok, %{quantity: threshold, notifier: notifier}} when current_level <= threshold ->
        alert = Alert.new(sku, current_level, threshold)
        dispatch_alert(alert, notifier)

      _ ->
        :ok
    end
  end

  defp dispatch_alert(%Alert{} = alert, notifier) do
    case Notifier.send(notifier, alert) do
      :ok ->
        Logger.info("reorder alert sent for SKU #{alert.sku} (level: #{alert.current_level})")

      {:error, reason} ->
        Logger.error("failed to send reorder alert for #{alert.sku}: #{reason}")
    end
  end

  defp schedule_scan, do: Process.send_after(self(), :scan, @scan_interval_ms)
end

defmodule Inventory.ReorderMonitor.Alert do
  @moduledoc false

  @enforce_keys [:sku, :current_level, :threshold, :triggered_at]
  defstruct [:sku, :current_level, :threshold, :triggered_at]

  @type t :: %__MODULE__{
          sku: String.t(),
          current_level: non_neg_integer(),
          threshold: non_neg_integer(),
          triggered_at: DateTime.t()
        }

  @spec new(String.t(), non_neg_integer(), non_neg_integer()) :: t()
  def new(sku, current, threshold) do
    %__MODULE__{sku: sku, current_level: current, threshold: threshold, triggered_at: DateTime.utc_now()}
  end
end

defmodule Inventory.ReorderMonitor.ThresholdStore do
  @moduledoc false

  @type entry :: %{quantity: non_neg_integer(), notifier: module()}
  @type t :: %{String.t() => entry()}

  @spec new() :: t()
  def new, do: %{}

  @spec put(t(), String.t(), non_neg_integer(), module()) :: t()
  def put(store, sku, qty, notifier), do: Map.put(store, sku, %{quantity: qty, notifier: notifier})

  @spec delete(t(), String.t()) :: t()
  def delete(store, sku), do: Map.delete(store, sku)

  @spec fetch(t(), String.t()) :: {:ok, entry()} | :error
  def fetch(store, sku), do: Map.fetch(store, sku)

  @spec all_skus(t()) :: [String.t()]
  def all_skus(store), do: Map.keys(store)
end

defmodule Inventory.ReorderMonitor.Notifier do
  @moduledoc "Behaviour for reorder alert delivery adapters."

  alias Inventory.ReorderMonitor.Alert

  @callback send(Alert.t()) :: :ok | {:error, String.t()}

  @spec send(module(), Alert.t()) :: :ok | {:error, String.t()}
  def send(notifier_module, alert), do: notifier_module.send(alert)

  @spec default() :: module()
  def default, do: Application.get_env(:inventory, :reorder_notifier, Inventory.ReorderMonitor.Notifiers.Log)
end
```
