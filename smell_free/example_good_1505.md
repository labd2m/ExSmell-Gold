```elixir
defmodule Catalog.Products do
  @moduledoc """
  Ecto context for managing product catalog entries.

  Handles product creation, filtering, pagination, and soft deletion.
  All database interactions are encapsulated here to keep schemas
  and query logic separate from business callers.
  """

  import Ecto.Query, warn: false

  alias Catalog.Repo
  alias Catalog.Products.Product

  @type filter_opts :: [
          category: String.t(),
          min_price_cents: non_neg_integer(),
          max_price_cents: non_neg_integer(),
          available: boolean()
        ]

  @type page_opts :: [page: pos_integer(), per_page: pos_integer()]

  @doc """
  Returns a paginated list of active products, optionally filtered.
  """
  @spec list_products(filter_opts(), page_opts()) :: [Product.t()]
  def list_products(filters \\ [], page_opts \\ []) do
    page = Keyword.get(page_opts, :page, 1)
    per_page = Keyword.get(page_opts, :per_page, 20)
    offset = (page - 1) * per_page

    Product
    |> where([p], is_nil(p.deleted_at))
    |> apply_filters(filters)
    |> order_by([p], asc: p.inserted_at)
    |> limit(^per_page)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Fetches a single active product by ID.

  Returns `{:ok, product}` or `{:error, :not_found}`.
  """
  @spec get_product(Ecto.UUID.t()) :: {:ok, Product.t()} | {:error, :not_found}
  def get_product(id) when is_binary(id) do
    case Repo.get_by(Product, id: id, deleted_at: nil) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end

  @doc """
  Creates a new product from the given attributes.

  Returns `{:ok, product}` or `{:error, changeset}`.
  """
  @spec create_product(map()) :: {:ok, Product.t()} | {:error, Ecto.Changeset.t()}
  def create_product(attrs) when is_map(attrs) do
    %Product{}
    |> Product.creation_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing product with the given attributes.
  """
  @spec update_product(Product.t(), map()) ::
          {:ok, Product.t()} | {:error, Ecto.Changeset.t()}
  def update_product(%Product{} = product, attrs) when is_map(attrs) do
    product
    |> Product.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Soft-deletes a product by setting its `deleted_at` timestamp.
  """
  @spec delete_product(Product.t()) :: {:ok, Product.t()} | {:error, Ecto.Changeset.t()}
  def delete_product(%Product{} = product) do
    product
    |> Product.deletion_changeset()
    |> Repo.update()
  end

  @spec apply_filters(Ecto.Query.t(), filter_opts()) :: Ecto.Query.t()
  defp apply_filters(query, []), do: query

  defp apply_filters(query, [{:category, category} | rest]) when is_binary(category) do
    query
    |> where([p], p.category == ^category)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:min_price_cents, min} | rest]) when is_integer(min) and min >= 0 do
    query
    |> where([p], p.price_cents >= ^min)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:max_price_cents, max} | rest]) when is_integer(max) and max >= 0 do
    query
    |> where([p], p.price_cents <= ^max)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:available, true} | rest]) do
    query
    |> where([p], p.stock_quantity > 0)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:available, false} | rest]) do
    query
    |> where([p], p.stock_quantity == 0)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [_unknown | rest]), do: apply_filters(query, rest)
end
```
