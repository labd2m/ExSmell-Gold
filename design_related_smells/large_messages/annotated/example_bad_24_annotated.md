# Annotated Example – Large Messages

| Field | Value |
|---|---|
| **Smell name** | Large messages |
| **Expected smell location** | `Inventory.SyncAgent.push_full_snapshot/1` |
| **Affected function(s)** | `push_full_snapshot/1` |
| **Short explanation** | The sync agent loads the complete in-memory inventory catalogue—thousands of SKUs with location vectors, pricing history, and supplier records—and sends the entire map to a downstream reconciliation process in one message. The deep-copy overhead for such a large structure blocks the agent and can stall the system under high catalogue volume. |

```elixir
defmodule Inventory.PriceRecord do
  defstruct [:currency, :amount, :effective_from, :effective_to, :source]

  @type t :: %__MODULE__{
          currency: String.t(),
          amount: float(),
          effective_from: Date.t(),
          effective_to: Date.t() | nil,
          source: String.t()
        }
end

defmodule Inventory.Supplier do
  defstruct [:id, :name, :lead_time_days, :min_order_qty, :contact_email]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          lead_time_days: non_neg_integer(),
          min_order_qty: non_neg_integer(),
          contact_email: String.t()
        }
end

defmodule Inventory.LocationStock do
  defstruct [:warehouse_id, :aisle, :bin, :quantity_on_hand, :quantity_reserved]

  @type t :: %__MODULE__{
          warehouse_id: String.t(),
          aisle: String.t(),
          bin: String.t(),
          quantity_on_hand: non_neg_integer(),
          quantity_reserved: non_neg_integer()
        }
end

defmodule Inventory.SKU do
  @enforce_keys [:id, :name, :category, :locations, :price_history, :suppliers]
  defstruct [
    :id,
    :name,
    :category,
    :locations,
    :price_history,
    :suppliers,
    :attributes,
    :hazmat,
    :weight_kg,
    :barcode
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          category: String.t(),
          locations: [Inventory.LocationStock.t()],
          price_history: [Inventory.PriceRecord.t()],
          suppliers: [Inventory.Supplier.t()],
          attributes: map(),
          hazmat: boolean(),
          weight_kg: float(),
          barcode: String.t()
        }
end

defmodule Inventory.CatalogueStore do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def snapshot, do: GenServer.call(__MODULE__, :snapshot, 60_000)

  @impl true
  def init(_), do: {:ok, build_catalogue()}

  @impl true
  def handle_call(:snapshot, _from, catalogue) do
    {:reply, catalogue, catalogue}
  end

  defp build_catalogue do
    today = Date.utc_today()

    Map.new(1..15_000, fn n ->
      sku = %Inventory.SKU{
        id: "SKU-#{String.pad_leading("#{n}", 8, "0")}",
        name: "Product #{n} – Industrial Grade",
        category: "cat_#{rem(n, 40) + 1}",
        barcode: "89#{String.pad_leading("#{n}", 10, "0")}",
        weight_kg: :rand.uniform() * 50,
        hazmat: rem(n, 100) == 0,
        attributes: %{
          colour: Enum.random(["red", "blue", "green", "black", "white"]),
          material: Enum.random(["steel", "plastic", "aluminium", "composite"]),
          certification: "ISO-#{9000 + rem(n, 10)}",
          shelf_life_days: :rand.uniform(730)
        },
        locations:
          Enum.map(1..6, fn wh ->
            %Inventory.LocationStock{
              warehouse_id: "WH-#{wh}",
              aisle: "#{<<65 + rem(n * wh, 26)::utf8>>}#{rem(wh, 10) + 1}",
              bin: "B#{String.pad_leading("#{rem(n, 100)}", 3, "0")}",
              quantity_on_hand: :rand.uniform(1000),
              quantity_reserved: :rand.uniform(200)
            }
          end),
        price_history:
          Enum.map(0..11, fn m ->
            %Inventory.PriceRecord{
              currency: "USD",
              amount: 10.0 + :rand.uniform() * 490,
              effective_from: Date.add(today, -30 * (12 - m)),
              effective_to: if(m < 11, do: Date.add(today, -30 * (11 - m)), else: nil),
              source: "ERP_SYNC"
            }
          end),
        suppliers:
          Enum.map(1..3, fn s ->
            %Inventory.Supplier{
              id: "SUPP-#{rem(n * s, 500) + 1}",
              name: "Supplier #{rem(n * s, 500) + 1} Co.",
              lead_time_days: :rand.uniform(60),
              min_order_qty: :rand.uniform(100),
              contact_email: "procurement@supplier#{rem(n * s, 500) + 1}.example.com"
            }
          end)
      }

      {sku.id, sku}
    end)
  end
end

defmodule Inventory.ReconciliationWorker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, %{}, opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:full_snapshot, catalogue}, _state) do
    {:noreply, catalogue}
  end
end

defmodule Inventory.SyncAgent do
  @moduledoc """
  Periodically pushes a full inventory snapshot to the reconciliation worker
  so it can detect discrepancies against the ERP system.
  """

  require Logger

  @spec push_full_snapshot(pid()) :: :ok
  def push_full_snapshot(reconciliation_pid) do
    Logger.info("Acquiring full inventory snapshot...")

    catalogue = Inventory.CatalogueStore.snapshot()

    Logger.info("Snapshot acquired: #{map_size(catalogue)} SKUs. Pushing to reconciliation worker...")

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because `catalogue` is a map with up to 15,000
    # SKU structs, each containing 6 location records, 12 price history entries,
    # and 3 supplier records—all deeply nested. Sending this in one process
    # message requires the BEAM to deep-copy the entire structure to the
    # receiver's heap, blocking the SyncAgent for an extended period and
    # increasing GC pressure on both processes.
    send(reconciliation_pid, {:full_snapshot, catalogue})
    # VALIDATION: SMELL END

    Logger.info("Full snapshot dispatched to reconciliation worker.")
    :ok
  end
end
```
