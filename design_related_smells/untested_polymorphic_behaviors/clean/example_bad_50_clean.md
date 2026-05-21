```elixir
defmodule Inventory.StockAdjuster do
  @moduledoc """
  Manages stock-level adjustments for warehouses: receiving, write-offs,
  cycle-count corrections, and inter-warehouse transfers.
  """

  alias Inventory.{StockRecord, AdjustmentLog, Warehouse, Product}

  @adjustment_types ~w(receive write_off cycle_count transfer_in transfer_out damage)a
  @max_comment_length 500

  def adjust_stock(warehouse_id, sku, quantity_delta, adjustment_type, opts \\ []) do
    unless adjustment_type in @adjustment_types do
      raise ArgumentError, "Unknown adjustment type: #{inspect(adjustment_type)}"
    end

    operator = Keyword.get(opts, :operator_id, nil)
    reference = Keyword.get(opts, :reference, nil)
    category = Keyword.get(opts, :category, :general)

    with {:ok, warehouse} <- Warehouse.fetch(warehouse_id),
         {:ok, product} <- Product.fetch_by_sku(sku),
         :ok <- validate_quantity(quantity_delta, adjustment_type),
         {:ok, current_stock} <- StockRecord.fetch(warehouse_id, sku),
         {:ok, comment} <- compose_adjustment_comment(category),
         :ok <- check_negative_stock(current_stock.quantity, quantity_delta) do
      new_quantity = current_stock.quantity + quantity_delta

      updated_record = %StockRecord{
        current_stock
        | quantity: new_quantity,
          last_adjusted_at: DateTime.utc_now()
      }

      log_entry = %{
        warehouse_id: warehouse.id,
        warehouse_name: warehouse.name,
        sku: sku,
        product_name: product.name,
        adjustment_type: adjustment_type,
        quantity_delta: quantity_delta,
        resulting_quantity: new_quantity,
        comment: comment,
        operator_id: operator,
        reference: reference,
        adjusted_at: DateTime.utc_now()
      }

      with {:ok, _} <- StockRecord.update(updated_record),
           :ok <- AdjustmentLog.write(log_entry) do
        {:ok, updated_record}
      end
    end
  end

  def compose_adjustment_comment(category) do
    label = "#{category}" |> String.upcase() |> String.replace("_", " ")

    comment = "Stock adjustment — Category: #{label}"

    if String.length(comment) > @max_comment_length do
      {:error, {:comment_too_long, String.length(comment)}}
    else
      {:ok, comment}
    end
  end

  def validate_quantity(delta, type) when is_integer(delta) do
    cond do
      type in ~w(receive transfer_in)a and delta <= 0 ->
        {:error, {:quantity_must_be_positive, type}}

      type in ~w(write_off transfer_out damage)a and delta >= 0 ->
        {:error, {:quantity_must_be_negative, type}}

      true ->
        :ok
    end
  end

  def validate_quantity(_, _), do: {:error, :quantity_must_be_integer}

  def check_negative_stock(current, delta) do
    if current + delta < 0 do
      {:error, {:insufficient_stock, current, delta}}
    else
      :ok
    end
  end

  def bulk_adjust(warehouse_id, adjustments) when is_list(adjustments) do
    Enum.reduce_while(adjustments, {:ok, []}, fn adj, {:ok, acc} ->
      %{sku: sku, delta: delta, type: type} = adj
      opts = Map.to_list(Map.drop(adj, [:sku, :delta, :type]))

      case adjust_stock(warehouse_id, sku, delta, type, opts) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      err -> err
    end
  end

  def stock_summary(warehouse_id) do
    case StockRecord.list_for_warehouse(warehouse_id) do
      {:ok, records} ->
        summary = %{
          warehouse_id: warehouse_id,
          total_skus: length(records),
          total_units: Enum.sum(Enum.map(records, & &1.quantity)),
          zero_stock_skus: Enum.count(records, &(&1.quantity == 0)),
          negative_stock_skus: Enum.count(records, &(&1.quantity < 0))
        }

        {:ok, summary}

      {:error, _} = err ->
        err
    end
  end
end
```
