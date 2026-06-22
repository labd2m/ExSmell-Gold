**File:** `example_good_1310.md`

```elixir
defmodule Inventory.ProductStock do
  @moduledoc "Schema representing the current stock level for a product SKU."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          sku: String.t(),
          quantity_on_hand: non_neg_integer(),
          quantity_reserved: non_neg_integer(),
          lock_version: pos_integer()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "product_stocks" do
    field :sku, :string
    field :quantity_on_hand, :integer, default: 0
    field :quantity_reserved, :integer, default: 0
    field :lock_version, :integer, default: 1
    timestamps()
  end

  @spec reserve_changeset(t(), pos_integer()) :: Ecto.Changeset.t()
  def reserve_changeset(%__MODULE__{} = stock, quantity) do
    available = stock.quantity_on_hand - stock.quantity_reserved

    stock
    |> change(
      quantity_reserved: stock.quantity_reserved + quantity,
      lock_version: stock.lock_version + 1
    )
    |> validate_number(:quantity_reserved,
      less_than_or_equal_to: stock.quantity_on_hand,
      message: "cannot reserve #{quantity} units, only #{available} available"
    )
    |> optimistic_lock(:lock_version)
  end

  @spec release_changeset(t(), pos_integer()) :: Ecto.Changeset.t()
  def release_changeset(%__MODULE__{} = stock, quantity) do
    change(stock,
      quantity_reserved: max(0, stock.quantity_reserved - quantity),
      lock_version: stock.lock_version + 1
    )
    |> optimistic_lock(:lock_version)
  end

  @spec receive_changeset(t(), pos_integer()) :: Ecto.Changeset.t()
  def receive_changeset(%__MODULE__{} = stock, quantity) do
    stock
    |> change(quantity_on_hand: stock.quantity_on_hand + quantity)
    |> validate_number(:quantity_on_hand, greater_than_or_equal_to: 0)
  end
end

defmodule Inventory.Reservations do
  @moduledoc """
  Manages stock reservations with optimistic locking to prevent
  overselling under concurrent request load.
  """

  alias Inventory.ProductStock
  alias MyApp.Repo

  @max_retries 3

  @type reservation_result ::
          {:ok, ProductStock.t()}
          | {:error, :insufficient_stock}
          | {:error, :sku_not_found}
          | {:error, Ecto.Changeset.t()}

  @spec reserve(String.t(), pos_integer()) :: reservation_result()
  def reserve(sku, quantity) when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    attempt_reserve(sku, quantity, @max_retries)
  end

  @spec release(String.t(), pos_integer()) :: {:ok, ProductStock.t()} | {:error, term()}
  def release(sku, quantity) when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Repo.get_by(ProductStock, sku: sku) do
      nil -> {:error, :sku_not_found}
      stock -> stock |> ProductStock.release_changeset(quantity) |> Repo.update()
    end
  end

  @spec available_quantity(String.t()) :: {:ok, non_neg_integer()} | {:error, :sku_not_found}
  def available_quantity(sku) when is_binary(sku) do
    case Repo.get_by(ProductStock, sku: sku) do
      nil -> {:error, :sku_not_found}
      stock -> {:ok, stock.quantity_on_hand - stock.quantity_reserved}
    end
  end

  defp attempt_reserve(_sku, _quantity, 0), do: {:error, :conflict_retry_exhausted}

  defp attempt_reserve(sku, quantity, retries_left) do
    case Repo.get_by(ProductStock, sku: sku) do
      nil ->
        {:error, :sku_not_found}

      stock ->
        available = stock.quantity_on_hand - stock.quantity_reserved

        if available < quantity do
          {:error, :insufficient_stock}
        else
          case stock |> ProductStock.reserve_changeset(quantity) |> Repo.update() do
            {:ok, _} = result ->
              result

            {:error, %Ecto.StaleEntryError{}} ->
              attempt_reserve(sku, quantity, retries_left - 1)

            {:error, _} = err ->
              err
          end
        end
    end
  end
end
```
