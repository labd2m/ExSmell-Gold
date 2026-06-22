```elixir
defmodule Catalog.ProductVariantContext do
  @moduledoc """
  Ecto context for managing product variants within the catalog domain.

  Handles creation, pricing updates, and stock adjustments for product
  variants. Inventory mutations are serialized through database-level
  advisory locks to prevent concurrent stock underflows.
  """

  alias Catalog.{Product, ProductVariant, StockMovement, Repo}
  alias Ecto.Multi

  @type variant_attrs :: %{
          sku: String.t(),
          label: String.t(),
          price_cents: pos_integer(),
          initial_stock: non_neg_integer()
        }

  @type stock_result ::
          {:ok, ProductVariant.t()}
          | {:error, :variant_not_found}
          | {:error, :insufficient_stock}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Creates a new product variant with initial stock.

  Returns `{:ok, variant}` on success or a changeset error on validation failure.
  """
  @spec create_variant(Ecto.UUID.t(), variant_attrs()) ::
          {:ok, ProductVariant.t()} | {:error, :product_not_found} | {:error, Ecto.Changeset.t()}
  def create_variant(product_id, attrs) when is_binary(product_id) and is_map(attrs) do
    case Repo.get(Product, product_id) do
      nil ->
        {:error, :product_not_found}

      product ->
        insert_variant_with_stock(product.id, attrs)
    end
  end

  @doc """
  Adjusts the stock quantity for a variant by the given delta.

  Positive deltas represent restocking; negative deltas represent
  fulfillment deductions. Returns `{:error, :insufficient_stock}` if
  the resulting quantity would go below zero.
  """
  @spec adjust_stock(Ecto.UUID.t(), integer(), String.t()) :: stock_result()
  def adjust_stock(variant_id, delta, reason) when is_binary(variant_id) and is_integer(delta) do
    Repo.transaction(fn ->
      variant = Repo.get(ProductVariant, variant_id, lock: "FOR UPDATE")

      cond do
        is_nil(variant) ->
          Repo.rollback(:variant_not_found)

        variant.stock_quantity + delta < 0 ->
          Repo.rollback(:insufficient_stock)

        true ->
          perform_stock_adjustment(variant, delta, reason)
      end
    end)
    |> normalize_transaction_result()
  end

  defp insert_variant_with_stock(product_id, %{initial_stock: initial_stock} = attrs) do
    variant_attrs = Map.drop(attrs, [:initial_stock])

    Multi.new()
    |> Multi.insert(:variant, ProductVariant.changeset(%ProductVariant{}, Map.merge(variant_attrs, %{
      product_id: product_id,
      stock_quantity: initial_stock
    })))
    |> Multi.insert(:movement, fn %{variant: variant} ->
      StockMovement.changeset(%StockMovement{}, %{
        variant_id: variant.id,
        delta: initial_stock,
        reason: "initial_stock",
        resulting_quantity: initial_stock
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{variant: variant}} -> {:ok, variant}
      {:error, :variant, changeset, _} -> {:error, changeset}
    end
  end

  defp perform_stock_adjustment(variant, delta, reason) do
    new_quantity = variant.stock_quantity + delta

    with {:ok, updated_variant} <-
           variant
           |> ProductVariant.changeset(%{stock_quantity: new_quantity})
           |> Repo.update(),
         {:ok, _movement} <-
           %StockMovement{}
           |> StockMovement.changeset(%{
             variant_id: variant.id,
             delta: delta,
             reason: reason,
             resulting_quantity: new_quantity
           })
           |> Repo.insert() do
      updated_variant
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp normalize_transaction_result({:ok, result}), do: {:ok, result}
  defp normalize_transaction_result({:error, :variant_not_found}), do: {:error, :variant_not_found}
  defp normalize_transaction_result({:error, :insufficient_stock}), do: {:error, :insufficient_stock}
  defp normalize_transaction_result({:error, changeset}), do: {:error, changeset}
end
```
