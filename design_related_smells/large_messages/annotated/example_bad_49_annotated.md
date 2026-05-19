# Annotated Example – Bad Code (Human Validation)

## Metadata

- **Smell name:** Large messages
- **Expected smell location:** `FulfilmentPlanner.plan/2` — the `send/2` call dispatching the full order queue to the allocation worker
- **Affected function(s):** `FulfilmentPlanner.plan/2`, `AllocationWorker.handle_info/2`
- **Short explanation:** The entire open-order queue — a large list of order maps with nested line items, address data, and carrier preferences — is sent in a single message to the allocation worker. This deep copy blocks the planner process; when order volumes spike (e.g. flash sales), the repeated sending of very large order lists can stall the planner and delay fulfilment planning.

---

```elixir
defmodule AllocationWorker do
  use GenServer
  require Logger

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{allocated: 0, pending: 0}, opts)
  end

  def stats(pid), do: GenServer.call(pid, :stats)

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:stats, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info({:allocate_orders, warehouse_id, orders}, state) do
    Logger.info("AllocationWorker: allocating #{length(orders)} orders from warehouse=#{warehouse_id}")

    allocated =
      Enum.count(orders, fn order ->
        all_items_available?(order.line_items)
      end)

    pending = length(orders) - allocated

    Logger.info("AllocationWorker: allocated=#{allocated} pending=#{pending}")

    {:noreply, %{state |
      allocated: state.allocated + allocated,
      pending: state.pending + pending
    }}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp all_items_available?(_line_items), do: :rand.uniform(10) > 2
end

defmodule FulfilmentPlanner do
  require Logger

  @doc """
  Loads the current open-order queue for a warehouse, applies priority
  sorting, and sends the full queue to the allocation worker which checks
  stock availability and assigns pick tasks to fulfilment staff.
  """
  def plan(worker_pid, warehouse_id) do
    Logger.info("FulfilmentPlanner: loading order queue for warehouse=#{warehouse_id}")

    orders =
      warehouse_id
      |> load_open_orders()
      |> Enum.sort_by(& &1.priority, :desc)

    Logger.info("FulfilmentPlanner: #{length(orders)} orders queued — sending to allocation worker")

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because the complete sorted order queue —
    # potentially tens of thousands of order maps, each with multiple line
    # items (themselves maps with SKU details and dimensions), full shipping
    # addresses, and carrier preferences — is deep-copied into the
    # AllocationWorker mailbox as a single send/2 call. The planner process
    # is stalled for the entire copy. During high-volume events the queue
    # can be very large, making the blocking effect severe.
    send(worker_pid, {:allocate_orders, warehouse_id, orders})
    # VALIDATION: SMELL END

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers — simulate loading a large open-order queue
  # ---------------------------------------------------------------------------

  defp load_open_orders(warehouse_id) do
    Enum.map(1..40_000, fn n ->
      order_id = "ORD-#{warehouse_id}-#{String.pad_leading(Integer.to_string(n), 9, "0")}"

      %{
        id: order_id,
        warehouse_id: warehouse_id,
        customer_id: "CUST-#{:rand.uniform(200_000)}",
        priority: :rand.uniform(10),
        status: :open,
        line_items: build_line_items(),
        shipping: %{
          address: %{
            name: "Customer #{n}",
            street: "#{:rand.uniform(9999)} Elm Street",
            city: Enum.random(["Chicago", "Houston", "Phoenix", "Philadelphia"]),
            state: Enum.random(["IL", "TX", "AZ", "PA"]),
            zip: "#{:rand.uniform(99999)}",
            country: "US"
          },
          method: Enum.random([:standard, :express, :overnight]),
          carrier: Enum.random(["UPS", "FedEx", "USPS", "DHL"]),
          insurance: :rand.uniform() > 0.8
        },
        payment: %{
          method: Enum.random([:credit_card, :paypal, :bank_transfer]),
          captured: true,
          amount: Decimal.new("#{:rand.uniform(999)}.#{:rand.uniform(99)}")
        },
        placed_at: DateTime.add(~U[2024-06-01 00:00:00Z], :rand.uniform(86_400), :second)
      }
    end)
  end

  defp build_line_items do
    Enum.map(1..:rand.uniform(8), fn i ->
      %{
        sku: "SKU-#{:rand.uniform(50_000)}",
        description: "Product line item #{i}",
        quantity: :rand.uniform(10),
        unit_weight_g: :rand.uniform(5_000),
        dimensions: %{length_mm: :rand.uniform(500), width_mm: :rand.uniform(500), height_mm: :rand.uniform(500)},
        requires_refrigeration: Enum.random([true, false])
      }
    end)
  end
end
```
