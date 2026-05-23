# Annotated Example — Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `Warehouse.PackingService.pack_outbound/2` and `Warehouse.PackingService.pack_transfer/2` |
| **Affected functions** | `pack_outbound/2`, `pack_transfer/2` |
| **Short explanation** | Both functions duplicate the fragile-item handling logic (filtering fragile items, selecting padded boxes, logging a compliance note). If the definition of fragile changes or padding rules evolve, both functions must be updated independently. |

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

  # ---------------------------------------------------------------------------
  # Outbound shipment packing
  # ---------------------------------------------------------------------------

  @doc """
  Generates a packing list for an outbound customer shipment.
  """
  def pack_outbound(order_id, warehouse_id) do
    with {:ok, items}     <- Repo.fetch_order_items(order_id),
         {:ok, warehouse} <- Repo.fetch_warehouse(warehouse_id) do

      batches = Enum.chunk_every(items, @max_items_per_box)

      packing_instructions =
        Enum.map(batches, fn batch ->
          # VALIDATION: SMELL START - Duplicated Code
          # VALIDATION: This is a smell because the fragile-item detection
          # and padded-box selection logic is copy-pasted identically in
          # pack_transfer/2. If a new fragile category is added or padding
          # rules change, both functions must be updated.
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
          # VALIDATION: SMELL END

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

  # ---------------------------------------------------------------------------
  # Internal transfer packing
  # ---------------------------------------------------------------------------

  @doc """
  Generates a packing list for an internal warehouse-to-warehouse transfer.
  """
  def pack_transfer(transfer_id, origin_warehouse_id) do
    with {:ok, items}     <- Repo.fetch_transfer_items(transfer_id),
         {:ok, warehouse} <- Repo.fetch_warehouse(origin_warehouse_id) do

      batches = Enum.chunk_every(items, @max_items_per_box)

      packing_instructions =
        Enum.map(batches, fn batch ->
          # VALIDATION: SMELL START - Duplicated Code
          # VALIDATION: This is a smell because the identical fragile-item
          # logic from pack_outbound/2 is reproduced here. A new fragile
          # category or padding rule must be applied in both functions.
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
          # VALIDATION: SMELL END

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
