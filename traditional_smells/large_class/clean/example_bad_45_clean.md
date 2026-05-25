```elixir
defmodule WarehouseOperations do
  @moduledoc """
  Comprehensive warehouse management: inbound receiving, pick/pack/dispatch
  workflows, cycle counting, damage recording, bin-location slotting, packing
  list generation, KPI dashboards, and capacity alerting.
  """

  require Logger
  import Ecto.Query
  alias Warehouse.Repo
  alias Warehouse.GoodsReceipt
  alias Warehouse.PickTask
  alias Warehouse.PackTask
  alias Warehouse.Shipment
  alias Warehouse.BinLocation
  alias Warehouse.CycleCount
  alias Warehouse.DamageReport
  alias Warehouse.Product

  @low_capacity_pct 0.10


  def receive_goods(purchase_order_id, line_items) do
    Repo.transaction(fn ->
      receipt_attrs = %{
        purchase_order_id: purchase_order_id,
        received_at: DateTime.utc_now(),
        status: :pending_putaway
      }

      receipt = Repo.insert!(GoodsReceipt.changeset(%GoodsReceipt{}, receipt_attrs))

      Enum.each(line_items, fn item ->
        product = Repo.get!(Product, item.product_id)

        product
        |> Product.changeset(%{stock_quantity: product.stock_quantity + item.quantity})
        |> Repo.update!()
      end)

      Logger.info("Goods receipt #{receipt.id} created for PO #{purchase_order_id}")
      receipt
    end)
  end


  def pick_items(order_id, picker_id) do
    order = Repo.get!(Warehouse.Order, order_id) |> Repo.preload(:order_items)

    pick_lines =
      Enum.map(order.order_items, fn item ->
        bin = find_bin_for_product(item.product_id)
        %{product_id: item.product_id, quantity: item.quantity, bin_id: bin && bin.id}
      end)

    task_attrs = %{
      order_id: order_id,
      picker_id: picker_id,
      pick_lines: Jason.encode!(pick_lines),
      status: :in_progress,
      started_at: DateTime.utc_now()
    }

    case Repo.insert(PickTask.changeset(%PickTask{}, task_attrs)) do
      {:ok, task} -> {:ok, task, pick_lines}
      {:error, cs} -> {:error, cs}
    end
  end

  defp find_bin_for_product(product_id) do
    from(b in BinLocation,
      where: b.product_id == ^product_id and b.quantity > 0,
      order_by: [asc: b.aisle, asc: b.slot],
      limit: 1
    )
    |> Repo.one()
  end


  def pack_order(order_id, packer_id) do
    pack_attrs = %{
      order_id: order_id,
      packer_id: packer_id,
      status: :packed,
      packed_at: DateTime.utc_now()
    }

    case Repo.insert(PackTask.changeset(%PackTask{}, pack_attrs)) do
      {:ok, task} ->
        Repo.update!(
          Warehouse.Order
          |> Repo.get!(order_id)
          |> Warehouse.Order.changeset(%{status: :packed})
        )
        {:ok, task}

      {:error, cs} ->
        {:error, cs}
    end
  end


  def dispatch_shipment(order_id, carrier_tracking_number) do
    order = Repo.get!(Warehouse.Order, order_id)

    shipment_attrs = %{
      order_id: order_id,
      tracking_number: carrier_tracking_number,
      dispatched_at: DateTime.utc_now()
    }

    with {:ok, shipment} <- Repo.insert(Shipment.changeset(%Shipment{}, shipment_attrs)),
         {:ok, _order}   <- Repo.update(Warehouse.Order.changeset(order, %{status: :dispatched})) do
      Logger.info("Order #{order_id} dispatched with tracking #{carrier_tracking_number}")
      {:ok, shipment}
    end
  end


  def conduct_cycle_count(bin_id) do
    bin = Repo.get!(BinLocation, bin_id)

    attrs = %{
      bin_id: bin_id,
      product_id: bin.product_id,
      expected_quantity: bin.quantity,
      status: :open,
      initiated_at: DateTime.utc_now()
    }

    Repo.insert(CycleCount.changeset(%CycleCount{}, attrs))
  end


  def record_damage(product_id, %{quantity: qty, reason: reason, reported_by: agent_id}) do
    product = Repo.get!(Product, product_id)

    Repo.transaction(fn ->
      product
      |> Product.changeset(%{stock_quantity: max(0, product.stock_quantity - qty)})
      |> Repo.update!()

      Repo.insert!(
        DamageReport.changeset(%DamageReport{}, %{
          product_id: product_id,
          quantity: qty,
          reason: reason,
          reported_by: agent_id,
          reported_at: DateTime.utc_now()
        })
      )
    end)
  end


  def assign_bin_location(product_id, %{aisle: aisle, rack: rack, slot: slot, capacity: capacity}) do
    attrs = %{
      product_id: product_id,
      aisle: aisle,
      rack: rack,
      slot: slot,
      capacity: capacity,
      quantity: 0
    }

    Repo.insert(
      BinLocation.changeset(%BinLocation{}, attrs),
      on_conflict: {:replace, [:aisle, :rack, :slot, :capacity]},
      conflict_target: [:product_id, :aisle, :rack, :slot]
    )
  end


  def generate_packing_list(order_id) do
    order = Repo.get!(Warehouse.Order, order_id) |> Repo.preload(:order_items)

    lines =
      Enum.map(order.order_items, fn item ->
        product = Repo.get!(Product, item.product_id)
        %{sku: product.sku, name: product.name, quantity: item.quantity}
      end)

    %{
      order_id: order.id,
      generated_at: DateTime.utc_now(),
      items: lines,
      total_units: Enum.sum(Enum.map(lines, & &1.quantity))
    }
  end


  def calculate_warehouse_kpis(date) do
    start_of_day = DateTime.new!(date, ~T[00:00:00], "UTC")
    end_of_day   = DateTime.new!(date, ~T[23:59:59], "UTC")

    dispatched_today =
      from(s in Shipment, where: s.dispatched_at >= ^start_of_day and s.dispatched_at <= ^end_of_day)
      |> Repo.aggregate(:count, :id)

    damages_today =
      from(d in DamageReport, where: d.reported_at >= ^start_of_day and d.reported_at <= ^end_of_day)
      |> Repo.aggregate(:count, :id)

    %{date: date, dispatched: dispatched_today, damages: damages_today}
  end


  def alert_low_bin_capacity(warehouse_id) do
    low_bins =
      from(b in BinLocation,
        where: b.warehouse_id == ^warehouse_id and b.quantity / b.capacity >= (1 - @low_capacity_pct),
        select: b
      )
      |> Repo.all()

    Enum.each(low_bins, fn bin ->
      Logger.warning("Bin #{bin.aisle}-#{bin.rack}-#{bin.slot} is near capacity (#{bin.quantity}/#{bin.capacity})")
      AlertService.send(:warehouse_bin_low, %{bin_id: bin.id, warehouse_id: warehouse_id})
    end)

    {:ok, length(low_bins)}
  end
end
```
