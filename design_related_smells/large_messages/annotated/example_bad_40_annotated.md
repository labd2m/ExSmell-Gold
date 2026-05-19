# Annotated Example – Bad Code (Human Validation)

## Metadata

- **Smell name:** Large messages
- **Expected smell location:** `InventorySync.push_snapshot/2` — the `GenServer.cast/2` call that sends the full warehouse snapshot map to the cache worker
- **Affected function(s):** `InventorySync.push_snapshot/2`, `InventoryCacheWorker.handle_cast/2`
- **Short explanation:** A deeply nested map representing the entire warehouse stock snapshot — with hundreds of thousands of SKU entries — is copied wholesale into the cache worker's mailbox via `GenServer.cast`. This large copy stalls the sender process and can saturate the BEAM scheduler when snapshots arrive frequently.

---

```elixir
defmodule InventoryCacheWorker do
  use GenServer
  require Logger

  @refresh_interval_ms 30_000

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{snapshot: %{}, last_updated: nil}, opts)
  end

  def get_stock(pid, sku) do
    GenServer.call(pid, {:get_stock, sku})
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(state) do
    schedule_refresh()
    {:ok, state}
  end

  @impl true
  def handle_call({:get_stock, sku}, _from, state) do
    qty = Map.get(state.snapshot, sku, 0)
    {:reply, {:ok, qty}, state}
  end

  @impl true
  def handle_cast({:update_snapshot, snapshot}, state) do
    Logger.info("InventoryCacheWorker: applying new snapshot (#{map_size(snapshot)} SKUs)")
    {:noreply, %{state | snapshot: snapshot, last_updated: DateTime.utc_now()}}
  end

  @impl true
  def handle_info(:refresh, state) do
    Logger.debug("InventoryCacheWorker: scheduled refresh tick")
    schedule_refresh()
    {:noreply, state}
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end
end

defmodule InventorySync do
  require Logger

  @doc """
  Pulls the full stock snapshot from the warehouse management system and
  sends it to the in-memory cache worker so that downstream services can
  look up current stock levels without hitting the database on every request.
  """
  def push_snapshot(cache_pid, warehouse_id) do
    Logger.info("InventorySync: pulling snapshot for warehouse=#{warehouse_id}")

    snapshot = load_warehouse_snapshot(warehouse_id)

    Logger.info("InventorySync: snapshot has #{map_size(snapshot)} SKU entries")

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because the entire warehouse snapshot map —
    # potentially containing hundreds of thousands of SKU → quantity entries
    # plus nested metadata — is deep-copied into the cache worker's mailbox
    # as a single GenServer.cast message. The copying of such a large structure
    # blocks the calling process and, when push_snapshot is called repeatedly
    # (e.g. every 30 s), causes sustained scheduling pressure on the VM.
    GenServer.cast(cache_pid, {:update_snapshot, snapshot})
    # VALIDATION: SMELL END

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers — simulate loading a large stock snapshot
  # ---------------------------------------------------------------------------

  defp load_warehouse_snapshot(warehouse_id) do
    Map.new(1..120_000, fn n ->
      sku = "WH#{warehouse_id}-SKU-#{String.pad_leading(Integer.to_string(n), 7, "0")}"

      qty_on_hand = :rand.uniform(5_000)
      qty_reserved = :rand.uniform(qty_on_hand)

      {sku,
       %{
         qty_on_hand: qty_on_hand,
         qty_reserved: qty_reserved,
         qty_available: qty_on_hand - qty_reserved,
         location: "AISLE-#{:rand.uniform(50)}-BIN-#{:rand.uniform(200)}",
         last_counted_at: ~U[2024-03-15 08:00:00Z],
         unit_weight_g: :rand.uniform(10_000),
         attributes: %{
           hazmat: false,
           refrigerated: Enum.random([true, false]),
           batch_tracked: Enum.random([true, false])
         }
       }}
    end)
  end
end
```
