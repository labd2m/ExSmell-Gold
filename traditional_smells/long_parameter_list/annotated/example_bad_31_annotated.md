# Annotated Example 31 — Long Parameter List

## Metadata

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Warehouse.Transfers.create_transfer/10` |
| **Affected function(s)** | `create_transfer/10` |
| **Explanation** | The function accepts 10 individual parameters covering origin/destination warehouses (from_warehouse_id, from_location_code, to_warehouse_id, to_location_code), transfer content (product_id, quantity, unit), and logistics metadata (requested_by, reason, expected_arrival_date). These clearly belong in a `%TransferRoute{}` and a `%TransferDetails{}` struct rather than a long flat positional list. |

---

```elixir
# VALIDATION: SMELL START - Long Parameter List
# VALIDATION: This is a smell because `create_transfer/10` takes ten individual
# positional parameters. The source location pair (from_warehouse_id,
# from_location_code), destination location pair (to_warehouse_id,
# to_location_code), cargo details (product_id, quantity, unit), and
# administrative metadata (requested_by, reason, expected_arrival_date)
# all form natural groupings that should be expressed as structs.
# Callers must track ten argument positions, and the two pairs of
# warehouse/location IDs are trivially easy to transpose.
defmodule Warehouse.Transfers do
  @moduledoc """
  Manages inter-warehouse stock transfer requests, reservation,
  and in-transit status tracking.
  """

  require Logger

  alias Warehouse.Repo
  alias Warehouse.Schemas.StockTransfer
  alias Warehouse.Schemas.StockReservation
  alias Warehouse.LocationRegistry
  alias Warehouse.StockLedger
  alias Warehouse.Mailer

  @valid_units ~w(piece kg litre box pallet)
  @max_transfer_quantity 100_000

  def create_transfer(
        from_warehouse_id,
        from_location_code,
        to_warehouse_id,
        to_location_code,
        product_id,
        quantity,
        unit,
        requested_by,
        reason,
        expected_arrival_date
      ) do
# VALIDATION: SMELL END
    with :ok <- validate_warehouses(from_warehouse_id, to_warehouse_id),
         :ok <- validate_locations(from_warehouse_id, from_location_code, to_warehouse_id, to_location_code),
         :ok <- validate_quantity(quantity),
         :ok <- validate_unit(unit),
         :ok <- validate_arrival_date(expected_arrival_date) do
      available = StockLedger.available(from_warehouse_id, from_location_code, product_id)

      if available < quantity do
        Logger.warn("Insufficient stock for transfer: need #{quantity}, have #{available}")
        {:error, {:insufficient_stock, available}}
      else
        transfer_attrs = %{
          from_warehouse_id: from_warehouse_id,
          from_location_code: from_location_code,
          to_warehouse_id: to_warehouse_id,
          to_location_code: to_location_code,
          product_id: product_id,
          quantity: quantity,
          unit: unit,
          requested_by: requested_by,
          reason: reason,
          expected_arrival_date: expected_arrival_date,
          status: :pending,
          inserted_at: DateTime.utc_now()
        }

        Repo.transaction(fn ->
          {:ok, transfer} = Repo.insert(StockTransfer.changeset(%StockTransfer{}, transfer_attrs))

          reservation_attrs = %{
            transfer_id: transfer.id,
            warehouse_id: from_warehouse_id,
            location_code: from_location_code,
            product_id: product_id,
            quantity: quantity,
            reserved_at: DateTime.utc_now()
          }

          {:ok, _} = Repo.insert(StockReservation.changeset(%StockReservation{}, reservation_attrs))

          StockLedger.reserve(from_warehouse_id, from_location_code, product_id, quantity)
          Mailer.notify_warehouse_manager(to_warehouse_id, transfer)
          Logger.info("Transfer #{transfer.id} created: #{quantity} #{unit} of product #{product_id}")
          transfer
        end)
      end
    end
  end

  defp validate_warehouses(from_id, to_id) do
    cond do
      from_id == to_id -> {:error, :same_warehouse}
      not LocationRegistry.warehouse_exists?(from_id) -> {:error, {:unknown_warehouse, :from}}
      not LocationRegistry.warehouse_exists?(to_id) -> {:error, {:unknown_warehouse, :to}}
      true -> :ok
    end
  end

  defp validate_locations(from_wh, from_loc, to_wh, to_loc) do
    cond do
      not LocationRegistry.location_exists?(from_wh, from_loc) ->
        {:error, {:unknown_location, :from}}

      not LocationRegistry.location_exists?(to_wh, to_loc) ->
        {:error, {:unknown_location, :to}}

      true ->
        :ok
    end
  end

  defp validate_quantity(q) when is_integer(q) and q > 0 and q <= @max_transfer_quantity, do: :ok
  defp validate_quantity(_), do: {:error, :invalid_quantity}

  defp validate_unit(u) when u in @valid_units, do: :ok
  defp validate_unit(u), do: {:error, {:unknown_unit, u}}

  defp validate_arrival_date(date) do
    case Date.from_iso8601(date) do
      {:ok, d} ->
        if Date.compare(d, Date.utc_today()) != :lt, do: :ok, else: {:error, :arrival_date_in_past}

      _ ->
        {:error, :invalid_arrival_date}
    end
  end
end
```
