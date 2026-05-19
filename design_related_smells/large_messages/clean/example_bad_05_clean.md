```elixir
defmodule Inventory.SupplierInfo do
  defstruct [:supplier_id, :name, :lead_time_days, :min_order_qty, :unit_cost_cents, :contacts]
end

defmodule Inventory.StockLevel do
  defstruct [:warehouse_id, :qty_on_hand, :qty_reserved, :qty_in_transit, :last_counted_at]
end

defmodule Inventory.SKU do
  @enforce_keys [:sku_id, :name, :category]
  defstruct [
    :sku_id,
    :name,
    :category,
    :barcode,
    :weight_grams,
    :dimensions_mm,
    :stock_levels,
    :suppliers,
    :reorder_threshold,
    :max_stock,
    :attributes,
    :image_urls
  ]
end

defmodule Inventory.WarehouseStore do
  @moduledoc "Simulates fetching a full inventory snapshot."

  @spec snapshot(String.t()) :: list(Inventory.SKU.t())
  def snapshot(warehouse_id) do
    Enum.map(1..15_000, fn i ->
      %Inventory.SKU{
        sku_id: "SKU-#{warehouse_id}-#{i}",
        name: "Product #{i}",
        category: Enum.random(["electronics", "apparel", "food", "tools"]),
        barcode: "789#{String.pad_leading("#{i}", 10, "0")}",
        weight_grams: 100 + rem(i, 5_000),
        dimensions_mm: %{l: 200, w: 150, h: 80},
        stock_levels: [
          %Inventory.StockLevel{
            warehouse_id: warehouse_id,
            qty_on_hand: rem(i * 7, 500),
            qty_reserved: rem(i * 3, 100),
            qty_in_transit: rem(i, 50),
            last_counted_at: DateTime.utc_now()
          }
        ],
        suppliers: Enum.map(1..3, fn j ->
          %Inventory.SupplierInfo{
            supplier_id: "SUP-#{j}",
            name: "Supplier #{j}",
            lead_time_days: j * 5,
            min_order_qty: 50 * j,
            unit_cost_cents: i * j * 10,
            contacts: ["buyer#{j}@supplier.com"]
          }
        end),
        reorder_threshold: 20,
        max_stock: 1_000,
        attributes: %{color: "blue", material: "plastic", hazmat: false},
        image_urls: ["https://cdn.example.com/sku/#{i}/main.jpg"]
      }
    end)
  end
end

defmodule Inventory.Reconciler do
  @moduledoc "GenServer that compares a live snapshot against system records."
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{discrepancies: []}, opts)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:reconcile, skus}, _from, state) do
    discrepancies =
      Enum.filter(skus, fn sku ->
        Enum.any?(sku.stock_levels, fn sl ->
          sl.qty_on_hand < sku.reorder_threshold
        end)
      end)

    new_state = %{state | discrepancies: discrepancies}
    {:reply, {:ok, length(discrepancies)}, new_state}
  end

  @impl true
  def handle_call(:report, _from, state) do
    {:reply, state.discrepancies, state}
  end
end

defmodule Inventory.ReconciliationJob do
  @moduledoc "Scheduled job that triggers inventory reconciliation per warehouse."

  require Logger

  @spec run(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def run(warehouse_id) do
    Logger.info("Starting reconciliation for warehouse #{warehouse_id}")

    {:ok, reconciler} = Inventory.Reconciler.start_link()

    snapshot = Inventory.WarehouseStore.snapshot(warehouse_id)

    Logger.info("Snapshot contains #{length(snapshot)} SKUs — sending to reconciler")

    result = GenServer.call(reconciler, {:reconcile, snapshot}, :infinity)

    case result do
      {:ok, count} ->
        Logger.info("Reconciliation complete — #{count} discrepancies found")
        {:ok, count}

      error ->
        Logger.error("Reconciliation failed: #{inspect(error)}")
        {:error, error}
    end
  end
end
```
