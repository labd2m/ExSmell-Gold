```elixir
defmodule Catalog.Product do
  @moduledoc "Ecto schema and changeset for a product in the merchandise catalog."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: pos_integer(),
          sku: String.t(),
          name: String.t(),
          price_cents: pos_integer(),
          currency: String.t(),
          stock_quantity: non_neg_integer(),
          active: boolean()
        }

  schema "products" do
    field :sku, :string
    field :name, :string
    field :price_cents, :integer
    field :currency, :string, default: "USD"
    field :stock_quantity, :integer, default: 0
    field :active, :boolean, default: true
    timestamps()
  end

  @required [:sku, :name, :price_cents]
  @optional [:currency, :stock_quantity, :active]

  @doc "Builds a changeset for creating or updating a product record."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(product, attrs) do
    product
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:price_cents, greater_than: 0)
    |> validate_number(:stock_quantity, greater_than_or_equal_to: 0)
    |> validate_length(:sku, min: 3, max: 32)
    |> unique_constraint(:sku)
  end
end

defmodule Catalog.Products do
  @moduledoc """
  Context for managing catalog products.
  Provides typed functions for creation, lookup, and stock adjustment operations.
  """

  alias Catalog.Product
  alias Catalog.Repo
  import Ecto.Query

  @doc "Returns all active products ordered by name ascending."
  @spec list_active() :: [Product.t()]
  def list_active do
    from(p in Product, where: p.active == true, order_by: [asc: p.name])
    |> Repo.all()
  end

  @doc "Looks up a product by its SKU."
  @spec get_by_sku(String.t()) :: {:ok, Product.t()} | {:error, :not_found}
  def get_by_sku(sku) when is_binary(sku) do
    case Repo.get_by(Product, sku: sku, active: true) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end

  @doc "Creates a new product from the given attributes."
  @spec create(map()) :: {:ok, Product.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    %Product{}
    |> Product.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Adjusts the stock quantity of a product by a signed delta."
  @spec adjust_stock(pos_integer(), integer()) ::
          {:ok, Product.t()} | {:error, :not_found | :insufficient_stock | Ecto.Changeset.t()}
  def adjust_stock(product_id, delta)
      when is_integer(product_id) and is_integer(delta) do
    with {:ok, product} <- fetch_by_id(product_id),
         {:ok, new_qty} <- compute_new_quantity(product.stock_quantity, delta) do
      product
      |> Product.changeset(%{stock_quantity: new_qty})
      |> Repo.update()
    end
  end

  defp fetch_by_id(id) do
    case Repo.get(Product, id) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end

  defp compute_new_quantity(current, delta) when current + delta >= 0,
    do: {:ok, current + delta}
  defp compute_new_quantity(_current, _delta),
    do: {:error, :insufficient_stock}
end
```
