```elixir
defmodule MyApp.InventoryCoordinator do
  @moduledoc """
  Coordinates core inventory operations including stock transfers,
  damage write-offs, and new product listings.
  """

  require Logger

  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Inventory.{Product, StockLevel, StockTransfer, DamageWriteOff}
  alias MyApp.Purchasing.SupplierCatalog
  alias MyApp.Notifications.Mailer
  alias MyApp.Audit.InventoryLog

  @min_transfer_quantity 1
  @writeoff_requires_approval_above 500.0
  @sku_pattern ~r/^[A-Z0-9\-]{6,24}$/

  @doc """
  Executes an inventory operation.

  Accepts one of:
  - `%StockTransfer{}`
  - `%DamageWriteOff{}`
  - `%Product{status: :draft}`

  ## Examples

      iex> MyApp.InventoryCoordinator.execute(%StockTransfer{from_warehouse_id: 1, to_warehouse_id: 2, sku: "WIDGET-XL", quantity: 50})
      {:ok, %StockTransfer{status: :completed}}

  """

  def execute(
        %StockTransfer{
          from_warehouse_id: from_id,
          to_warehouse_id: to_id,
          sku: sku,
          quantity: quantity,
          requested_by: requested_by
        } = transfer
      )
      when is_integer(quantity) and quantity >= @min_transfer_quantity and from_id != to_id do
    Logger.info(
      "Stock transfer requested: #{quantity}x #{sku} from warehouse #{from_id} to #{to_id}"
    )

    source_stock =
      Repo.one(
        from s in StockLevel,
          where: s.warehouse_id == ^from_id and s.sku == ^sku,
          select: s
      )

    cond do
      is_nil(source_stock) ->
        Logger.warn("SKU #{sku} not found at warehouse #{from_id}")
        {:error, :sku_not_found}

      source_stock.available < quantity ->
        Logger.warn(
          "Insufficient stock for transfer: available #{source_stock.available}, requested #{quantity}"
        )
        {:error, :insufficient_stock}

      true ->
        {:ok, completed_transfer} =
          Repo.transaction(fn ->
            Repo.update_all(
              from(s in StockLevel,
                where: s.warehouse_id == ^from_id and s.sku == ^sku
              ),
              inc: [available: -quantity]
            )

            Repo.insert!(
              StockLevel.changeset(%StockLevel{}, %{
                warehouse_id: to_id,
                sku: sku,
                available: quantity
              }),
              on_conflict: [inc: [available: quantity]],
              conflict_target: [:warehouse_id, :sku]
            )

            Repo.update!(
              StockTransfer.changeset(transfer, %{
                status: :completed,
                completed_at: DateTime.utc_now()
              })
            )
          end)

        InventoryLog.record(:stock_transfer, %{
          sku: sku,
          quantity: quantity,
          from: from_id,
          to: to_id,
          actor: requested_by
        })

        Mailer.notify_warehouse_manager(to_id, :inbound_transfer, completed_transfer)
        Logger.info("Transfer of #{quantity}x #{sku} completed from #{from_id} to #{to_id}")
        {:ok, completed_transfer}
    end
  end

  def execute(
        %DamageWriteOff{
          warehouse_id: warehouse_id,
          sku: sku,
          quantity: quantity,
          unit_cost: unit_cost,
          damage_description: description,
          reported_by: reported_by
        } = writeoff
      )
      when is_integer(quantity) and quantity > 0 do
    total_loss = quantity * unit_cost
    Logger.info("Damage write-off: #{quantity}x #{sku} at warehouse #{warehouse_id}, loss: #{total_loss}")

    stock =
      Repo.one(
        from s in StockLevel,
          where: s.warehouse_id == ^warehouse_id and s.sku == ^sku
      )

    cond do
      is_nil(stock) ->
        Logger.warn("Write-off failed: SKU #{sku} not found at warehouse #{warehouse_id}")
        {:error, :sku_not_found}

      stock.available < quantity ->
        Logger.warn("Write-off quantity #{quantity} exceeds available #{stock.available} for #{sku}")
        {:error, :insufficient_stock}

      total_loss > @writeoff_requires_approval_above ->
        Logger.warn(
          "Write-off for #{sku} exceeds approval threshold (#{total_loss}), flagging for review"
        )

        {:ok, pending} =
          Repo.update(
            DamageWriteOff.changeset(writeoff, %{
              status: :pending_approval,
              total_loss: total_loss
            })
          )

        Mailer.notify_inventory_manager_writeoff_approval(pending)
        {:ok, :pending_approval}

      true ->
        {:ok, approved_writeoff} =
          Repo.transaction(fn ->
            Repo.update_all(
              from(s in StockLevel,
                where: s.warehouse_id == ^warehouse_id and s.sku == ^sku
              ),
              inc: [available: -quantity]
            )

            Repo.update!(
              DamageWriteOff.changeset(writeoff, %{
                status: :applied,
                total_loss: total_loss,
                applied_at: DateTime.utc_now()
              })
            )
          end)

        InventoryLog.record(:damage_writeoff, %{
          sku: sku,
          quantity: quantity,
          warehouse_id: warehouse_id,
          total_loss: total_loss,
          description: description,
          actor: reported_by
        })

        Logger.info("Write-off applied: #{quantity}x #{sku}, total loss: #{total_loss}")
        {:ok, approved_writeoff}
    end
  end

  def execute(%Product{status: :draft, sku: sku, name: name, supplier_id: supplier_id} = product) do
    Logger.info("Publishing new product listing: #{sku} — #{name}")

    cond do
      not Regex.match?(@sku_pattern, sku) ->
        Logger.warn("Invalid SKU format: #{sku}")
        {:error, :invalid_sku_format}

      Repo.exists?(from p in Product, where: p.sku == ^sku and p.status != :archived) ->
        Logger.warn("Duplicate SKU detected: #{sku}")
        {:error, :sku_already_exists}

      not SupplierCatalog.supplier_active?(supplier_id) ->
        Logger.warn("Supplier #{supplier_id} is inactive, cannot list product #{sku}")
        {:error, :inactive_supplier}

      true ->
        {:ok, published} =
          Repo.update(
            Product.changeset(product, %{
              status: :active,
              published_at: DateTime.utc_now()
            })
          )

        InventoryLog.record(:product_published, %{
          sku: sku,
          supplier_id: supplier_id,
          name: name
        })

        Mailer.notify_purchasing_team_new_listing(published)
        Logger.info("Product #{sku} published successfully")
        {:ok, published}
    end
  end

end
```
