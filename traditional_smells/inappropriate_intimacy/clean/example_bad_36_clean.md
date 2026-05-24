```elixir
defmodule Inventory.StockAdjustmentService do
  @moduledoc """
  Handles stock level adjustments across warehouse bins, including
  inter-bin transfers, write-offs, and receipt processing.
  """

  require Logger

  alias Inventory.{StockAdjustment, StockLevel, AuditEntry}
  alias Warehouse.{Bin, Zone}
  alias Catalog.Product

  @write_off_approval_threshold 50

  def record_receipt(product_id, quantity, location_code) do
    with {:ok, level} <- StockLevel.fetch_or_create(product_id, location_code) do
      updated = %{level | quantity: level.quantity + quantity}
      StockLevel.persist(updated)
      AuditEntry.record(:receipt, %{
        product_id:    product_id,
        quantity:      quantity,
        location_code: location_code
      })
      {:ok, updated}
    end
  end

  def write_off(product_id, quantity, reason, approver_id) do
    cond do
      quantity <= 0 ->
        {:error, :invalid_quantity}

      quantity > @write_off_approval_threshold and is_nil(approver_id) ->
        {:error, :approval_required}

      true ->
        with {:ok, adj} <- StockAdjustment.create(%{
               product_id:  product_id,
               quantity:    -quantity,
               reason:      reason,
               approver_id: approver_id,
               type:        :write_off,
               created_at:  DateTime.utc_now()
             }) do
          AuditEntry.record(:write_off, %{adjustment_id: adj.id, approver_id: approver_id})
          {:ok, adj}
        end
    end
  end

  def transfer_between_bins(product_id, quantity, from_bin_id, to_bin_id) do
    from_bin = Bin.find(from_bin_id)
    to_bin   = Bin.find(to_bin_id)
    product  = Product.find(product_id)

    cond do
      from_bin.active != true ->
        {:error, :source_bin_inactive}

      to_bin.active != true ->
        {:error, :destination_bin_inactive}

      to_bin.hazmat_restricted == true and product.hazmat == true ->
        {:error, :hazmat_not_allowed_in_destination}

      to_bin.capacity_units - to_bin.used_units < quantity ->
        {:error, :destination_bin_insufficient_capacity}

      true ->
        to_zone = Zone.find(to_bin.zone_id)

        if product.requires_climate_control and to_zone.climate_controlled != true do
          {:error, :climate_control_required}
        else
          with {:ok, _from} <- StockLevel.adjust(product_id, from_bin_id, -quantity),
               {:ok, _to}   <- StockLevel.adjust(product_id, to_bin_id,   quantity) do
            AuditEntry.record(:bin_transfer, %{
              product_id:  product_id,
              quantity:    quantity,
              from_bin_id: from_bin_id,
              to_bin_id:   to_bin_id,
              transferred_at: DateTime.utc_now()
            })
            {:ok, :transferred}
          end
        end
    end
  end

  def current_levels(product_id) do
    StockLevel.list(product_id: product_id)
  end

  def low_stock_products(threshold \\ 10) do
    StockLevel.find_below_threshold(threshold)
  end

  def relocate_product(product_id, from_location, to_location) do
    with {:ok, level} <- StockLevel.fetch(product_id, from_location) do
      transfer_between_bins(product_id, level.quantity, from_location, to_location)
    end
  end

  def recount(product_id, bin_id, physical_count) do
    with {:ok, level} <- StockLevel.fetch_or_create(product_id, bin_id) do
      variance = physical_count - level.quantity
      updated  = %{level | quantity: physical_count, last_counted_at: DateTime.utc_now()}

      with {:ok, saved} <- StockLevel.persist(updated) do
        AuditEntry.record(:recount, %{
          product_id: product_id,
          bin_id:     bin_id,
          variance:   variance
        })
        {:ok, saved}
      end
    end
  end
end
```
