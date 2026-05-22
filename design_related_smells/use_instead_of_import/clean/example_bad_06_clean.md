```elixir
defmodule Inventory.UnitUtils do
  @moduledoc """
  Unit-of-measure conversion utilities shared across the inventory platform.
  """

  @kg_per_lb 0.453592
  @cm_per_in 2.54

  def lbs_to_kg(lbs), do: Float.round(lbs * @kg_per_lb, 4)
  def kg_to_lbs(kg),  do: Float.round(kg / @kg_per_lb, 4)

  def inches_to_cm(inches), do: Float.round(inches * @cm_per_in, 4)
  def cm_to_inches(cm),     do: Float.round(cm / @cm_per_in, 4)

  def normalize_weight(value, :lb), do: lbs_to_kg(value)
  def normalize_weight(value, :kg), do: value

  def volume_liters(length_cm, width_cm, height_cm) do
    Float.round(length_cm * width_cm * height_cm / 1_000, 4)
  end
end

defmodule Inventory.ValidationHelpers do
  @moduledoc """
  Reusable stock-level and SKU validation rules shared across inventory modules
  via `use`.
  """

  defmacro __using__(_opts) do
    quote do
      import Inventory.UnitUtils  # propagates unit utilities into every caller

      def valid_sku?(sku) when is_binary(sku) do
        String.match?(sku, ~r/^[A-Z]{2,4}-\d{4,8}(-[A-Z0-9]+)?$/)
      end

      def valid_quantity?(qty) when is_integer(qty) and qty >= 0, do: true
      def valid_quantity?(_), do: false

      def valid_reorder_point?(reorder, quantity) when is_integer(reorder) and is_integer(quantity) do
        reorder >= 0 and reorder < quantity
      end

      def below_threshold?(%{quantity: qty, reorder_point: rp}), do: qty <= rp

      def validate_stock_entry(entry) do
        cond do
          not valid_sku?(entry[:sku])                                    -> {:error, {:invalid_sku, entry[:sku]}}
          not valid_quantity?(entry[:quantity])                          -> {:error, :invalid_quantity}
          not valid_reorder_point?(entry[:reorder_point], entry[:quantity]) -> {:error, :invalid_reorder_point}
          true                                                           -> :ok
        end
      end
    end
  end
end

defmodule Inventory.StockManager do
  @moduledoc """
  Manages inventory stock levels, adjustments, reservations, and reorder alerts.
  Handles multi-warehouse stock distribution and low-stock notification triggers.
  """

  use Inventory.ValidationHelpers

  @low_stock_threshold 10

  def add_entry(stock, entry) do
    with :ok <- validate_stock_entry(entry) do
      updated = Map.update(stock, entry.sku, entry, fn existing ->
        %{existing | quantity: existing.quantity + entry.quantity}
      end)
      {:ok, updated}
    end
  end

  def reserve(stock, sku, quantity) do
    case Map.fetch(stock, sku) do
      {:ok, entry} when entry.quantity >= quantity ->
        updated = Map.put(stock, sku, %{entry |
          quantity: entry.quantity - quantity,
          reserved: (entry[:reserved] || 0) + quantity
        })
        {:ok, updated}

      {:ok, _} ->
        {:error, :insufficient_stock}

      :error ->
        {:error, :sku_not_found}
    end
  end

  def release_reservation(stock, sku, quantity) do
    case Map.fetch(stock, sku) do
      {:ok, entry} ->
        reserved = max(0, (entry[:reserved] || 0) - quantity)
        updated  = Map.put(stock, sku, %{entry |
          quantity: entry.quantity + quantity,
          reserved: reserved
        })
        {:ok, updated}

      :error ->
        {:error, :sku_not_found}
    end
  end

  def adjust(stock, sku, delta) when is_integer(delta) do
    case Map.fetch(stock, sku) do
      {:ok, entry} ->
        new_qty = entry.quantity + delta

        if valid_quantity?(new_qty) do
          {:ok, Map.put(stock, sku, %{entry | quantity: new_qty})}
        else
          {:error, :quantity_below_zero}
        end

      :error ->
        {:error, :sku_not_found}
    end
  end

  def low_stock_skus(stock) do
    stock
    |> Enum.filter(fn {_sku, entry} -> below_threshold?(entry) end)
    |> Enum.map(fn {sku, entry} -> {sku, entry.quantity, entry.reorder_point} end)
  end

  def reorder_alerts(stock) do
    stock
    |> Enum.filter(fn {_sku, entry} -> entry.quantity <= @low_stock_threshold end)
    |> Enum.map(fn {sku, entry} ->
      %{sku: sku, current_qty: entry.quantity, reorder_qty: entry.reorder_quantity}
    end)
  end

  def remove_entry(stock, sku) do
    if Map.has_key?(stock, sku) do
      {:ok, Map.delete(stock, sku)}
    else
      {:error, :sku_not_found}
    end
  end

  def snapshot(stock) do
    %{
      total_skus:        map_size(stock),
      total_units:       stock |> Map.values() |> Enum.map(& &1.quantity) |> Enum.sum(),
      low_stock_count:   stock |> Enum.count(fn {_, e} -> below_threshold?(e) end),
      captured_at:       DateTime.utc_now()
    }
  end
end
```
