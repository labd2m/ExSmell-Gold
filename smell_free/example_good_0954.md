```elixir
defmodule Commerce.WishlistContext do
  @moduledoc """
  Manages customer wishlists. A customer may maintain multiple named
  wishlists. Items are added by SKU and carry optional notes. The context
  supports sharing a wishlist with other users via a signed URL, converting
  a wishlist to a cart, and detecting when a wishlisted item goes on sale.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Commerce.{Wishlist, WishlistItem, Product}

  @type customer_id :: String.t()
  @type wishlist_id :: Ecto.UUID.t()

  @doc "Creates a new named wishlist for `customer_id`."
  @spec create(customer_id(), String.t()) ::
          {:ok, Wishlist.t()} | {:error, Ecto.Changeset.t()}
  def create(customer_id, name) when is_binary(customer_id) and is_binary(name) do
    attrs = %{customer_id: customer_id, name: String.trim(name), public: false}
    %Wishlist{} |> Wishlist.changeset(attrs) |> Repo.insert()
  end

  @doc "Adds a product SKU to `wishlist_id`. Idempotent — duplicate SKUs are skipped."
  @spec add_item(wishlist_id(), String.t(), String.t() | nil) ::
          {:ok, WishlistItem.t()} | {:error, :wishlist_not_found | Ecto.Changeset.t()}
  def add_item(wishlist_id, sku, note \\ nil)
      when is_binary(wishlist_id) and is_binary(sku) do
    case Repo.get(Wishlist, wishlist_id) do
      nil ->
        {:error, :wishlist_not_found}

      _wishlist ->
        attrs = %{wishlist_id: wishlist_id, sku: sku, note: note}

        %WishlistItem{}
        |> WishlistItem.changeset(attrs)
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:wishlist_id, :sku])
    end
  end

  @doc "Removes a SKU from `wishlist_id`."
  @spec remove_item(wishlist_id(), String.t()) :: :ok
  def remove_item(wishlist_id, sku) when is_binary(wishlist_id) and is_binary(sku) do
    Repo.delete_all(from(i in WishlistItem, where: i.wishlist_id == ^wishlist_id and i.sku == ^sku))
    :ok
  end

  @doc "Returns all wishlists for `customer_id` with item counts."
  @spec list(customer_id()) :: [Wishlist.t()]
  def list(customer_id) when is_binary(customer_id) do
    from(w in Wishlist,
      where: w.customer_id == ^customer_id,
      order_by: [asc: w.inserted_at],
      preload: [:wishlist_items]
    )
    |> Repo.all()
  end

  @doc "Returns wishlisted SKUs that have recently had their price reduced."
  @spec sale_items(wishlist_id()) :: [%{sku: String.t(), old_price: non_neg_integer(), new_price: non_neg_integer()}]
  def sale_items(wishlist_id) when is_binary(wishlist_id) do
    skus =
      from(i in WishlistItem, where: i.wishlist_id == ^wishlist_id, select: i.sku)
      |> Repo.all()

    from(p in Product,
      where: p.sku in ^skus and not is_nil(p.previous_price_cents) and p.price_cents < p.previous_price_cents,
      select: %{sku: p.sku, old_price: p.previous_price_cents, new_price: p.price_cents}
    )
    |> Repo.all()
  end

  @doc "Makes `wishlist_id` publicly accessible via a shareable URL."
  @spec make_public(wishlist_id()) :: {:ok, Wishlist.t()} | {:error, :not_found}
  def make_public(wishlist_id) when is_binary(wishlist_id) do
    case Repo.get(Wishlist, wishlist_id) do
      nil -> {:error, :not_found}
      wishlist -> wishlist |> Wishlist.changeset(%{public: true}) |> Repo.update()
    end
  end
end
```
