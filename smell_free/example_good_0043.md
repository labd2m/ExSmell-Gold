```elixir
defmodule Store.Catalog do
  @moduledoc """
  The Catalog context manages products and categories within the store domain.
  All external interactions with catalog data are routed through this module's
  public interface to maintain clear data-ownership and boundary semantics.
  """

  import Ecto.Query, warn: false

  alias Store.Repo
  alias Store.Catalog.{Product, Category}

  @type product_params :: %{
          optional(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:sku) => String.t(),
          optional(:price_cents) => non_neg_integer(),
          optional(:category_id) => Ecto.UUID.t(),
          optional(:active) => boolean()
        }

  @doc """
  Returns active products. Supports `category_id`, `page`, and `per_page` options.
  """
  @spec list_products(keyword()) :: [Product.t()]
  def list_products(opts \\ []) do
    per_page = Keyword.get(opts, :per_page, 20)
    page = Keyword.get(opts, :page, 1)
    category_id = Keyword.get(opts, :category_id)

    Product
    |> where([p], p.active == true)
    |> maybe_filter_by_category(category_id)
    |> order_by([p], asc: p.name)
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> Repo.all()
  end

  @doc """
  Fetches a single product by its UUID. Returns `{:error, :not_found}` if absent.
  """
  @spec fetch_product(Ecto.UUID.t()) :: {:ok, Product.t()} | {:error, :not_found}
  def fetch_product(id) when is_binary(id) do
    case Repo.get(Product, id) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end

  @doc """
  Creates a product from the given params. Returns the new record or a
  changeset on validation failure.
  """
  @spec create_product(product_params()) :: {:ok, Product.t()} | {:error, Ecto.Changeset.t()}
  def create_product(params) when is_map(params) do
    %Product{}
    |> Product.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Updates a product's attributes. Returns the updated record or a changeset error.
  """
  @spec update_product(Product.t(), product_params()) ::
          {:ok, Product.t()} | {:error, Ecto.Changeset.t()}
  def update_product(%Product{} = product, params) when is_map(params) do
    product
    |> Product.changeset(params)
    |> Repo.update()
  end

  @doc """
  Archives a product by marking it inactive. The record is preserved.
  """
  @spec archive_product(Product.t()) :: {:ok, Product.t()} | {:error, Ecto.Changeset.t()}
  def archive_product(%Product{} = product) do
    update_product(product, %{active: false})
  end

  @doc """
  Returns all categories sorted alphabetically by name.
  """
  @spec list_categories() :: [Category.t()]
  def list_categories do
    Category
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  @doc """
  Fetches a single category by its UUID.
  """
  @spec fetch_category(Ecto.UUID.t()) :: {:ok, Category.t()} | {:error, :not_found}
  def fetch_category(id) when is_binary(id) do
    case Repo.get(Category, id) do
      nil -> {:error, :not_found}
      category -> {:ok, category}
    end
  end

  defp maybe_filter_by_category(query, nil), do: query

  defp maybe_filter_by_category(query, category_id) when is_binary(category_id) do
    where(query, [p], p.category_id == ^category_id)
  end
end
```
