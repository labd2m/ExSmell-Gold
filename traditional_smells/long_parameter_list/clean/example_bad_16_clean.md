```elixir
defmodule Inventory.Products do
  @moduledoc """
  Manages product catalogue entries, initial stock levels, and pricing for
  the inventory subsystem.
  """

  require Logger

  alias Inventory.Repo
  alias Inventory.Schemas.Product
  alias Inventory.Schemas.StockEntry
  alias Inventory.SearchIndex

  @valid_units ~w(piece kg litre box pair)

  def add_product(
        sku,
        name,
        description,
        category,
        brand,
        weight_kg,
        unit,
        cost_price,
        sale_price,
        initial_quantity,
        reorder_threshold
      ) do
    with :ok <- validate_sku(sku),
         :ok <- validate_name(name),
         :ok <- validate_prices(cost_price, sale_price),
         :ok <- validate_unit(unit),
         :ok <- validate_stock_params(initial_quantity, reorder_threshold) do
      product_attrs = %{
        sku: String.upcase(String.trim(sku)),
        name: String.trim(name),
        description: description,
        category: category,
        brand: brand,
        weight_kg: weight_kg,
        unit: unit,
        cost_price: cost_price,
        sale_price: sale_price,
        active: true,
        inserted_at: DateTime.utc_now()
      }

      Repo.transaction(fn ->
        case Repo.insert(Product.changeset(%Product{}, product_attrs)) do
          {:ok, product} ->
            stock_attrs = %{
              product_id: product.id,
              quantity: initial_quantity,
              reserved: 0,
              reorder_threshold: reorder_threshold,
              updated_at: DateTime.utc_now()
            }

            {:ok, _stock} = Repo.insert(StockEntry.changeset(%StockEntry{}, stock_attrs))
            SearchIndex.index_product(product)
            Logger.info("Product #{product.sku} added with #{initial_quantity} units in stock")
            product

          {:error, changeset} ->
            Logger.error("Product creation failed: #{inspect(changeset.errors)}")
            Repo.rollback(:creation_failed)
        end
      end)
    end
  end

  defp validate_sku(sku) do
    if Regex.match?(~r/^[A-Za-z0-9\-_]{3,30}$/, sku || "") do
      :ok
    else
      {:error, :invalid_sku}
    end
  end

  defp validate_name(name) do
    if is_binary(name) and String.length(String.trim(name)) >= 2 do
      :ok
    else
      {:error, :invalid_name}
    end
  end

  defp validate_prices(cost, sale) do
    cond do
      not is_number(cost) or cost < 0 -> {:error, :invalid_cost_price}
      not is_number(sale) or sale < 0 -> {:error, :invalid_sale_price}
      sale < cost -> {:error, :sale_below_cost}
      true -> :ok
    end
  end

  defp validate_unit(unit) when unit in @valid_units, do: :ok
  defp validate_unit(u), do: {:error, {:unknown_unit, u}}

  defp validate_stock_params(qty, threshold) do
    cond do
      not is_integer(qty) or qty < 0 -> {:error, :invalid_quantity}
      not is_integer(threshold) or threshold < 0 -> {:error, :invalid_reorder_threshold}
      true -> :ok
    end
  end
end
```
