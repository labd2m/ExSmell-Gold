```elixir
defmodule Commerce.Catalog.ProductContext do
  @moduledoc """
  Public context for managing catalog products.
  All database interactions go through this module; callers do not interact
  with `Repo` or schema modules directly.
  """

  alias Commerce.Catalog.{Product, ProductQuery}
  alias Commerce.Repo

  @doc """
  Returns a paginated list of active products, optionally filtered by category.

  ## Options
    - `:category` - filter by category slug string
    - `:page` - 1-based page number (default: 1)
    - `:per_page` - results per page, max 100 (default: 20)
  """
  @spec list_active(keyword()) :: {:ok, [Product.t()], map()} | {:error, String.t()}
  def list_active(opts \\ []) do
    with {:ok, page} <- validate_positive_integer(opts, :page, 1),
         {:ok, per_page} <- validate_per_page(opts) do
      results =
        ProductQuery.base()
        |> ProductQuery.active()
        |> ProductQuery.filter_category(Keyword.get(opts, :category))
        |> ProductQuery.paginate(page, per_page)
        |> Repo.all()

      meta = %{page: page, per_page: per_page}
      {:ok, results, meta}
    end
  end

  @doc """
  Fetches a single product by its slug.
  """
  @spec fetch_by_slug(String.t()) :: {:ok, Product.t()} | {:error, :not_found}
  def fetch_by_slug(slug) when is_binary(slug) do
    case Repo.get_by(Product, slug: slug, active: true) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end

  @doc """
  Creates a new product from validated attributes.
  """
  @spec create(map()) :: {:ok, Product.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    %Product{}
    |> Product.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing product's attributes.
  """
  @spec update(Product.t(), map()) :: {:ok, Product.t()} | {:error, Ecto.Changeset.t()}
  def update(%Product{} = product, attrs) when is_map(attrs) do
    product
    |> Product.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deactivates a product without deleting it.
  """
  @spec deactivate(Product.t()) :: {:ok, Product.t()} | {:error, Ecto.Changeset.t()}
  def deactivate(%Product{} = product) do
    product
    |> Product.deactivate_changeset()
    |> Repo.update()
  end

  defp validate_positive_integer(opts, key, default) do
    val = Keyword.get(opts, key, default)

    if is_integer(val) and val >= 1 do
      {:ok, val}
    else
      {:error, "#{key} must be a positive integer"}
    end
  end

  defp validate_per_page(opts) do
    val = Keyword.get(opts, :per_page, 20)

    cond do
      not is_integer(val) -> {:error, "per_page must be an integer"}
      val < 1 -> {:error, "per_page must be at least 1"}
      val > 100 -> {:error, "per_page cannot exceed 100"}
      true -> {:ok, val}
    end
  end
end
```
