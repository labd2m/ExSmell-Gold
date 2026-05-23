```elixir
defmodule Warehouse.PackingService do
  @moduledoc """
  Determines packing requirements for outbound customer shipments and
  internal warehouse transfers, including special handling for fragile goods.
  """

  alias Warehouse.{Item, Box, PackingList, ComplianceLog, Repo}

  @fragile_categories      [:glassware, :electronics, :ceramics, :medical_devices]
  @padded_box_types        [:bubble_wrap_box, :foam_lined_box, :double_walled_box]
  @default_box_type        :standard_box
  @max_items_per_box       12


  @doc """
  Generates a packing list for an outbound customer shipment.
  """
  def pack_outbound(order_id, warehouse_id) do
    with {:ok, items}     <- Repo.fetch_order_items(order_id),
         {:ok, warehouse} <- Repo.fetch_warehouse(warehouse_id) do

      batches = Enum.chunk_every(items, @max_items_per_box)

      packing_instructions =
        Enum.map(batches, fn batch ->
          fragile_items = Enum.filter(batch, fn item ->
            item.category in @fragile_categories or item.fragile_flag
          end)

          box_type =
            if Enum.any?(fragile_items) do
              padded_box = Repo.find_available_box(warehouse_id, @padded_box_types)
              if padded_box, do: padded_box.type, else: @default_box_type
            else
              @default_box_type
            end

          if Enum.any?(fragile_items) do
            ComplianceLog.record(:fragile_packing, %{
              order_id:    order_id,
              item_ids:    Enum.map(fragile_items, & &1.id),
              box_type:    box_type,
              recorded_at: DateTime.utc_now()
            })
          end

          %{
            items:    batch,
            box_type: box_type,
            weight_g: Enum.sum(Enum.map(batch, & &1.weight_g))
          }
        end)

      packing_list = %PackingList{
        order_id:     order_id,
        warehouse_id: warehouse_id,
        batches:      packing_instructions,
        type:         :outbound,
        created_at:   DateTime.utc_now()
      }

      {:ok, packing_list}
    end
  end


  @doc """
  Generates a packing list for an internal warehouse-to-warehouse transfer.
  """
  def pack_transfer(transfer_id, origin_warehouse_id) do
    with {:ok, items}     <- Repo.fetch_transfer_items(transfer_id),
         {:ok, warehouse} <- Repo.fetch_warehouse(origin_warehouse_id) do

      batches = Enum.chunk_every(items, @max_items_per_box)

      packing_instructions =
        Enum.map(batches, fn batch ->
          fragile_items = Enum.filter(batch, fn item ->
            item.category in @fragile_categories or item.fragile_flag
          end)

          box_type =
            if Enum.any?(fragile_items) do
              padded_box = Repo.find_available_box(origin_warehouse_id, @padded_box_types)
              if padded_box, do: padded_box.type, else: @default_box_type
            else
              @default_box_type
            end

          if Enum.any?(fragile_items) do
            ComplianceLog.record(:fragile_packing, %{
              transfer_id: transfer_id,
              item_ids:    Enum.map(fragile_items, & &1.id),
              box_type:    box_type,
              recorded_at: DateTime.utc_now()
            })
          end

          %{
            items:    batch,
            box_type: box_type,
            weight_g: Enum.sum(Enum.map(batch, & &1.weight_g))
          }
        end)

      packing_list = %PackingList{
        transfer_id:  transfer_id,
        warehouse_id: origin_warehouse_id,
        batches:      packing_instructions,
        type:         :transfer,
        created_at:   DateTime.utc_now()
      }

      {:ok, packing_list}
    end
  end
end
```
