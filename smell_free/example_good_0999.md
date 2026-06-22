```elixir
defmodule MyApp.Commerce.WishlistManager do
  @moduledoc """
  Manages customer wishlists: adding and removing products, checking
  membership, and converting a wishlist to a cart. Wishlists are
  user-scoped so that all queries are automatically filtered by
  `user_id` and cross-user access is structurally impossible.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Commerce.{WishlistItem, Cart, CartItem}
  alias MyApp.Catalogue.Product

  @type user_id :: String.t()
  @type product_id :: String.t()

  @doc """
  Adds `product_id` to `user_id`'s wishlist. Returns `{:ok, item}` or
  `{:error, :already_wishlisted}` when already present.
  """
  @spec add(user_id(), product_id()) ::
          {:ok, WishlistItem.t()} | {:error, :already_wishlisted} | {:error, Ecto.Changeset.t()}
  def add(user_id, product_id) when is_binary(user_id) and is_binary(product_id) do
    case Repo.get_by(WishlistItem, user_id: user_id, product_id: product_id) do
      %WishlistItem{} -> {:error, :already_wishlisted}
      nil ->
        %WishlistItem{}
        |> WishlistItem.changeset(%{user_id: user_id, product_id: product_id})
        |> Repo.insert()
    end
  end

  @doc "Removes `product_id` from `user_id`'s wishlist."
  @spec remove(user_id(), product_id()) :: :ok
  def remove(user_id, product_id) when is_binary(user_id) and is_binary(product_id) do
    WishlistItem
    |> where([w], w.user_id == ^user_id and w.product_id == ^product_id)
    |> Repo.delete_all()

    :ok
  end

  @doc "Returns `true` when `product_id` is on `user_id`'s wishlist."
  @spec wishlisted?(user_id(), product_id()) :: boolean()
  def wishlisted?(user_id, product_id) when is_binary(user_id) and is_binary(product_id) do
    WishlistItem
    |> where([w], w.user_id == ^user_id and w.product_id == ^product_id)
    |> Repo.exists?()
  end

  @doc "Returns all wishlist items for `user_id` with product details preloaded."
  @spec list(user_id()) :: [WishlistItem.t()]
  def list(user_id) when is_binary(user_id) do
    WishlistItem
    |> where([w], w.user_id == ^user_id)
    |> join(:inner, [w], p in Product, on: p.id == w.product_id and p.active == true)
    |> order_by([w], desc: w.inserted_at)
    |> preload(:product)
    |> Repo.all()
  end

  @doc """
  Moves all in-stock wishlist items into an existing or new cart.
  Out-of-stock items remain on the wishlist. Returns the updated cart.
  """
  @spec move_to_cart(user_id(), Cart.t() | nil) :: {:ok, Cart.t()} | {:error, term()}
  def move_to_cart(user_id, cart \\ nil) when is_binary(user_id) do
    items = list(user_id)
    in_stock = Enum.filter(items, fn item -> item.product.available end)

    Repo.transaction(fn ->
      target_cart = cart || create_cart(user_id)

      Enum.each(in_stock, fn item ->
        %CartItem{}
        |> CartItem.changeset(%{
          cart_id: target_cart.id,
          product_id: item.product_id,
          sku: item.product.sku,
          quantity: 1,
          unit_price_cents: item.product.price_cents
        })
        |> Repo.insert(on_conflict: :nothing)

        remove(user_id, item.product_id)
      end)

      Repo.preload(target_cart, :items)
    end)
  end

  @spec create_cart(user_id()) :: Cart.t()
  defp create_cart(user_id) do
    %Cart{}
    |> Cart.changeset(%{customer_id: user_id})
    |> Repo.insert!()
  end
end
```
