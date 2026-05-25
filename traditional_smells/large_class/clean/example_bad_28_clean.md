```elixir
defmodule WarehouseOperations do
  @moduledoc """
  Handles all warehouse floor operations from receiving to shipment.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Warehouse.{
    ReceivingRecord,
    PutAwayTask,
    PickList,
    PickListItem,
    PackRecord,
    CycleCount,
    CycleCountLine,
    Bin,
    BinAssignment
  }
  alias MyApp.Inventory.StockLevel

  @default_bin_capacity 500
  @cycle_count_variance_threshold 0.05


  def receive_purchase_order(po_id, received_lines) do
    {:ok, record} =
      Repo.insert(%ReceivingRecord{
        purchase_order_id: po_id,
        received_at: DateTime.utc_now(),
        status: :in_progress
      })

    discrepancies =
      Enum.flat_map(received_lines, fn line ->
        case validate_received_line(po_id, line) do
          :ok ->
            update_stock_on_receipt(line)
            schedule_put_away(record.id, line)
            []

          {:error, reason} ->
            [%{sku: line.sku, reason: reason}]
        end
      end)

    status = if Enum.empty?(discrepancies), do: :completed, else: :completed_with_discrepancies

    record
    |> ReceivingRecord.changeset(%{status: status, discrepancies: discrepancies})
    |> Repo.update()

    Logger.info("PO #{po_id} received. Discrepancies: #{length(discrepancies)}")
    {:ok, %{record: record, discrepancies: discrepancies}}
  end

  defp validate_received_line(po_id, %{sku: sku, quantity: qty}) do
    expected =
      Repo.one(
        from l in MyApp.Procurement.PurchaseOrderLine,
          where: l.purchase_order_id == ^po_id and l.sku == ^sku,
          select: l.quantity
      )

    cond do
      is_nil(expected) -> {:error, :sku_not_on_po}
      qty > expected -> {:error, :over_shipment}
      true -> :ok
    end
  end

  defp update_stock_on_receipt(%{sku: sku, quantity: qty, warehouse_id: wh_id}) do
    case Repo.get_by(StockLevel, sku: sku, warehouse_id: wh_id) do
      nil ->
        Repo.insert(%StockLevel{sku: sku, warehouse_id: wh_id, quantity: qty})

      sl ->
        sl |> StockLevel.changeset(%{quantity: sl.quantity + qty}) |> Repo.update()
    end
  end

  defp schedule_put_away(receiving_record_id, line) do
    bin = find_available_bin(line.sku, line.warehouse_id)

    Repo.insert(%PutAwayTask{
      receiving_record_id: receiving_record_id,
      sku: line.sku,
      quantity: line.quantity,
      bin_id: bin && bin.id,
      status: :pending,
      created_at: DateTime.utc_now()
    })
  end


  def complete_put_away(task_id, bin_id) do
    task = Repo.get!(PutAwayTask, task_id)

    with {:ok, _} <- assign_to_bin(task.sku, bin_id, task.quantity),
         {:ok, updated} <-
           task
           |> PutAwayTask.changeset(%{
             status: :completed,
             bin_id: bin_id,
             completed_at: DateTime.utc_now()
           })
           |> Repo.update() do
      {:ok, updated}
    end
  end

  defp assign_to_bin(sku, bin_id, quantity) do
    case Repo.get_by(BinAssignment, sku: sku, bin_id: bin_id) do
      nil ->
        Repo.insert(%BinAssignment{sku: sku, bin_id: bin_id, quantity: quantity})

      assignment ->
        assignment
        |> BinAssignment.changeset(%{quantity: assignment.quantity + quantity})
        |> Repo.update()
    end
  end


  def generate_pick_list(order_id) do
    items = Repo.all(from i in MyApp.Orders.OrderItem, where: i.order_id == ^order_id)

    {:ok, pick_list} =
      Repo.insert(%PickList{order_id: order_id, status: :open, created_at: DateTime.utc_now()})

    Enum.each(items, fn item ->
      bin = find_bin_with_stock(item.sku)

      Repo.insert(%PickListItem{
        pick_list_id: pick_list.id,
        sku: item.sku,
        quantity: item.quantity,
        bin_id: bin && bin.id,
        status: :pending
      })
    end)

    {:ok, pick_list}
  end

  def confirm_picked(pick_list_item_id) do
    item = Repo.get!(PickListItem, pick_list_item_id)

    with {:ok, _} <- deduct_bin_stock(item.sku, item.bin_id, item.quantity) do
      item
      |> PickListItem.changeset(%{status: :picked, picked_at: DateTime.utc_now()})
      |> Repo.update()
    end
  end

  defp deduct_bin_stock(sku, bin_id, quantity) do
    case Repo.get_by(BinAssignment, sku: sku, bin_id: bin_id) do
      nil ->
        {:error, :bin_assignment_not_found}

      assignment ->
        new_qty = assignment.quantity - quantity

        if new_qty < 0 do
          {:error, :insufficient_bin_stock}
        else
          assignment
          |> BinAssignment.changeset(%{quantity: new_qty})
          |> Repo.update()
        end
    end
  end

  def record_pack(pick_list_id, package_dimensions, weight_kg) do
    Repo.insert(%PackRecord{
      pick_list_id: pick_list_id,
      dimensions: package_dimensions,
      weight_kg: weight_kg,
      packed_at: DateTime.utc_now()
    })
  end


  def start_cycle_count(warehouse_id, skus) do
    {:ok, count} =
      Repo.insert(%CycleCount{
        warehouse_id: warehouse_id,
        status: :in_progress,
        started_at: DateTime.utc_now()
      })

    Enum.each(skus, fn sku ->
      system_qty =
        case Repo.get_by(StockLevel, sku: sku, warehouse_id: warehouse_id) do
          nil -> 0
          sl -> sl.quantity
        end

      Repo.insert(%CycleCountLine{
        cycle_count_id: count.id,
        sku: sku,
        system_quantity: system_qty,
        counted_quantity: nil
      })
    end)

    {:ok, count}
  end

  def record_count(cycle_count_id, sku, counted_qty) do
    line = Repo.get_by!(CycleCountLine, cycle_count_id: cycle_count_id, sku: sku)

    variance =
      if line.system_quantity > 0 do
        abs(counted_qty - line.system_quantity) / line.system_quantity
      else
        if counted_qty > 0, do: 1.0, else: 0.0
      end

    flag = variance > @cycle_count_variance_threshold

    line
    |> CycleCountLine.changeset(%{counted_quantity: counted_qty, variance: variance, flagged: flag})
    |> Repo.update()
  end

  def finalize_cycle_count(cycle_count_id) do
    lines = Repo.all(from l in CycleCountLine, where: l.cycle_count_id == ^cycle_count_id)
    count = Repo.get!(CycleCount, cycle_count_id)

    Enum.each(lines, fn line ->
      if not is_nil(line.counted_quantity) do
        case Repo.get_by(StockLevel, sku: line.sku, warehouse_id: count.warehouse_id) do
          nil -> Repo.insert(%StockLevel{sku: line.sku, warehouse_id: count.warehouse_id, quantity: line.counted_quantity})
          sl -> sl |> StockLevel.changeset(%{quantity: line.counted_quantity}) |> Repo.update()
        end
      end
    end)

    count
    |> CycleCount.changeset(%{status: :completed, completed_at: DateTime.utc_now()})
    |> Repo.update()
  end


  def create_bin(warehouse_id, aisle, row, level, capacity \\ @default_bin_capacity) do
    Repo.insert(%Bin{
      warehouse_id: warehouse_id,
      aisle: aisle,
      row: row,
      level: level,
      capacity: capacity,
      active: true
    })
  end

  defp find_available_bin(_sku, warehouse_id) do
    Repo.one(
      from b in Bin,
        where: b.warehouse_id == ^warehouse_id and b.active == true,
        limit: 1
    )
  end

  defp find_bin_with_stock(sku) do
    Repo.one(
      from a in BinAssignment,
        join: b in Bin,
        on: a.bin_id == b.id,
        where: a.sku == ^sku and a.quantity > 0,
        order_by: [asc: a.quantity],
        limit: 1,
        select: b
    )
  end

  def deactivate_bin(bin_id) do
    Repo.get!(Bin, bin_id)
    |> Bin.changeset(%{active: false})
    |> Repo.update()
  end
end
```
