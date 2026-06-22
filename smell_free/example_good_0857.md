```elixir
defmodule Catalog.VariantContext do
  @moduledoc """
  Manages product variants: combinations of attribute values such as size
  and colour for a parent product. Variants carry their own SKU, price,
  and stock status. The context enforces unique SKUs across all variants
  and validates that attribute values reference declared parent-level
  attributes. Queries always scope to the parent product for data isolation.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Catalog.{Product, Variant}

  @type product_id :: Ecto.UUID.t()
  @type variant_id :: Ecto.UUID.t()
  @type attributes :: %{String.t() => String.t()}

  @doc "Creates a variant for `product_id` with the given attributes and price."
  @spec create(product_id(), String.t(), pos_integer(), attributes()) ::
          {:ok, Variant.t()}
          | {:error, :product_not_found | :duplicate_sku | :invalid_attributes | Ecto.Changeset.t()}
  def create(product_id, sku, price_cents, attributes)
      when is_binary(product_id) and is_binary(sku)
      and is_integer(price_cents) and price_cents > 0
      and is_map(attributes) do
    with {:ok, product} <- fetch_product(product_id),
         :ok <- check_sku_unique(sku),
         :ok <- validate_attributes(product, attributes) do
      attrs = %{product_id: product_id, sku: sku, price_cents: price_cents, attributes: attributes, active: true}
      %Variant{} |> Variant.changeset(attrs) |> Repo.insert()
    end
  end

  @doc "Updates a variant's price or active status."
  @spec update(Variant.t(), map()) :: {:ok, Variant.t()} | {:error, Ecto.Changeset.t()}
  def update(%Variant{} = variant, params) when is_map(params) do
    variant |> Variant.update_changeset(params) |> Repo.update()
  end

  @doc "Returns all active variants for `product_id` sorted by price ascending."
  @spec list_for_product(product_id()) :: [Variant.t()]
  def list_for_product(product_id) when is_binary(product_id) do
    from(v in Variant,
      where: v.product_id == ^product_id and v.active == true,
      order_by: [asc: v.price_cents]
    )
    |> Repo.all()
  end

  @doc "Fetches a variant by ID, scoped to `product_id`."
  @spec fetch(product_id(), variant_id()) :: {:ok, Variant.t()} | {:error, :not_found}
  def fetch(product_id, variant_id)
      when is_binary(product_id) and is_binary(variant_id) do
    case Repo.get_by(Variant, id: variant_id, product_id: product_id) do
      nil -> {:error, :not_found}
      variant -> {:ok, variant}
    end
  end

  @doc "Deactivates a variant, hiding it from the storefront."
  @spec deactivate(Variant.t()) :: {:ok, Variant.t()} | {:error, :already_inactive}
  def deactivate(%Variant{active: false}), do: {:error, :already_inactive}

  def deactivate(%Variant{} = variant) do
    variant |> Variant.update_changeset(%{active: false}) |> Repo.update()
  end

  defp fetch_product(product_id) do
    case Repo.get(Product, product_id) do
      nil -> {:error, :product_not_found}
      product -> {:ok, product}
    end
  end

  defp check_sku_unique(sku) do
    if Repo.exists?(from(v in Variant, where: v.sku == ^sku)) do
      {:error, :duplicate_sku}
    else
      :ok
    end
  end

  defp validate_attributes(%Product{allowed_attributes: allowed}, attributes)
       when is_map(allowed) do
    invalid = Map.keys(attributes) |> Enum.reject(&Map.has_key?(allowed, &1))

    if Enum.empty?(invalid), do: :ok, else: {:error, :invalid_attributes}
  end

  defp validate_attributes(%Product{}, _attributes), do: :ok
end
```
