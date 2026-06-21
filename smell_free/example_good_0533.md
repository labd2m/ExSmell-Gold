```elixir
defmodule Catalog.BundleContext do
  @moduledoc """
  Manages product bundle definitions: products sold together at a
  combined price. Bundle prices are validated to ensure they are
  lower than the sum of constituent product prices, enforcing the
  promotional intent. All context operations go through Ecto and the
  Repo so query scoping and transactional integrity are preserved.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Catalog.{Bundle, BundleItem, Product}

  @type bundle_id :: Ecto.UUID.t()
  @type create_params :: %{
          name: String.t(),
          bundle_price_cents: pos_integer(),
          currency: String.t(),
          product_ids: [Ecto.UUID.t()]
        }

  @doc """
  Creates a new bundle. Validates that the bundle price is strictly less
  than the sum of constituent product prices. Returns an error if any
  product ID is unknown or the price invariant is violated.
  """
  @spec create(create_params()) ::
          {:ok, Bundle.t()} | {:error, :price_not_discounted | :products_not_found | Ecto.Changeset.t()}
  def create(%{product_ids: ids} = params) when is_list(ids) and length(ids) >= 2 do
    Repo.transaction(fn ->
      products = fetch_products(ids)

      cond do
        length(products) < length(ids) ->
          Repo.rollback(:products_not_found)

        params.bundle_price_cents >= sum_product_prices(products) ->
          Repo.rollback(:price_not_discounted)

        true ->
          with {:ok, bundle} <- insert_bundle(params),
               :ok <- insert_bundle_items(bundle.id, products) do
            Repo.preload(bundle, :bundle_items)
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  @doc "Returns all active bundles with their constituent items preloaded."
  @spec list_active() :: [Bundle.t()]
  def list_active do
    Bundle
    |> where([b], b.active == true)
    |> order_by([b], asc: b.name)
    |> preload(:bundle_items)
    |> Repo.all()
  end

  @doc "Fetches a bundle by ID with items preloaded."
  @spec fetch(bundle_id()) :: {:ok, Bundle.t()} | {:error, :not_found}
  def fetch(bundle_id) when is_binary(bundle_id) do
    query = from(b in Bundle, where: b.id == ^bundle_id, preload: :bundle_items)
    case Repo.one(query) do
      nil -> {:error, :not_found}
      bundle -> {:ok, bundle}
    end
  end

  @doc "Deactivates a bundle without deleting it."
  @spec deactivate(Bundle.t()) :: {:ok, Bundle.t()} | {:error, Ecto.Changeset.t()}
  def deactivate(%Bundle{} = bundle) do
    bundle |> Bundle.changeset(%{active: false}) |> Repo.update()
  end

  @doc "Returns the discount amount in cents for a bundle versus buying items separately."
  @spec savings_cents(Bundle.t()) :: non_neg_integer()
  def savings_cents(%Bundle{bundle_price_cents: price, bundle_items: items})
      when is_list(items) do
    individual_total = Enum.sum_by(items, & &1.product_price_cents)
    max(0, individual_total - price)
  end

  defp fetch_products(ids) do
    Repo.all(from(p in Product, where: p.id in ^ids))
  end

  defp sum_product_prices(products) do
    Enum.sum_by(products, & &1.price_cents)
  end

  defp insert_bundle(params) do
    %Bundle{}
    |> Bundle.changeset(Map.drop(params, [:product_ids]))
    |> Repo.insert()
  end

  defp insert_bundle_items(bundle_id, products) do
    Enum.reduce_while(products, :ok, fn product, _acc ->
      attrs = %{bundle_id: bundle_id, product_id: product.id, product_price_cents: product.price_cents}
      case %BundleItem{} |> BundleItem.changeset(attrs) |> Repo.insert() do
        {:ok, _} -> {:cont, :ok}
        {:error, cs} -> {:halt, {:error, cs}}
      end
    end)
  end
end
```
