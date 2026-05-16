```elixir
defmodule Inventory.StockAdjuster do
  @moduledoc """
  Applies manual stock adjustments (corrections, write-offs, returns) to
  inventory records and emits audit log entries for each change.
  """

  require Logger

  @valid_reasons ~w(correction write_off return transfer damaged)

  @type stock_record :: %{
          sku: String.t(),
          warehouse_id: String.t(),
          quantity: integer(),
          reserved: integer(),
          last_updated: DateTime.t()
        }

  @type adjustment :: %{optional(atom()) => term()}

  @spec apply_adjustment(stock_record(), adjustment()) ::
          {:ok, stock_record()} | {:error, String.t()}
  def apply_adjustment(%{} = record, adjustment) do
    qty          = adjustment[:quantity]
    reason       = adjustment[:reason]
    warehouse_id = adjustment[:warehouse_id]

    with :ok <- validate_reason(reason),
         :ok <- validate_quantity(qty, record),
         :ok <- validate_warehouse(warehouse_id, record) do
      new_quantity = record.quantity + qty

      updated_record = %{
        record
        | quantity: new_quantity,
          last_updated: DateTime.utc_now()
      }

      emit_audit(record, updated_record, reason, warehouse_id)

      {:ok, updated_record}
    end
  end

  @spec validate_reason(String.t() | nil) :: :ok | {:error, String.t()}
  defp validate_reason(nil) do
    {:error, "Adjustment reason is required"}
  end

  defp validate_reason(reason) when reason in @valid_reasons, do: :ok

  defp validate_reason(reason) do
    {:error, "Invalid adjustment reason: #{reason}"}
  end

  @spec validate_quantity(integer() | nil, stock_record()) :: :ok | {:error, String.t()}
  defp validate_quantity(nil, _record) do
    {:error, "Adjustment quantity is required"}
  end

  defp validate_quantity(qty, record) when is_integer(qty) do
    available = record.quantity - record.reserved

    cond do
      qty == 0 ->
        {:error, "Adjustment quantity must be non-zero"}

      qty < 0 && abs(qty) > available ->
        {:error,
         "Cannot reduce stock below reserved amount. Available: #{available}, Requested: #{qty}"}

      true ->
        :ok
    end
  end

  defp validate_quantity(qty, _record) do
    {:error, "Quantity must be an integer, got: #{inspect(qty)}"}
  end

  @spec validate_warehouse(String.t() | nil, stock_record()) :: :ok | {:error, String.t()}
  defp validate_warehouse(nil, _record), do: :ok

  defp validate_warehouse(warehouse_id, record) do
    if warehouse_id == record.warehouse_id do
      :ok
    else
      {:error,
       "Warehouse mismatch: record belongs to #{record.warehouse_id}, " <>
         "adjustment targets #{warehouse_id}"}
    end
  end

  @spec emit_audit(stock_record(), stock_record(), String.t(), String.t() | nil) :: :ok
  defp emit_audit(before, after_, reason, warehouse_id) do
    Logger.info("Stock adjustment applied",
      sku: before.sku,
      warehouse_id: warehouse_id || before.warehouse_id,
      reason: reason,
      before_qty: before.quantity,
      after_qty: after_.quantity,
      delta: after_.quantity - before.quantity
    )
  end
end
```
