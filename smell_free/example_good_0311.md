```elixir
defmodule Marketplace.ListingContext do
  @moduledoc """
  The Listing context owns the lifecycle of marketplace listings from
  draft through published and archived states. Price change history is
  recorded on every update so buyers can see how a listing's price evolved.
  All reads return only publicly visible data unless the caller passes
  the owning seller's ID.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Marketplace.{Listing, PriceHistory}

  @type seller_id :: String.t()
  @type listing_id :: Ecto.UUID.t()
  @type create_params :: %{
          title: String.t(),
          description: String.t(),
          price_cents: pos_integer(),
          currency: String.t(),
          category_slug: String.t()
        }

  @doc "Creates a draft listing for `seller_id`."
  @spec create(seller_id(), create_params()) ::
          {:ok, Listing.t()} | {:error, Ecto.Changeset.t()}
  def create(seller_id, params) when is_binary(seller_id) and is_map(params) do
    attrs = Map.merge(params, %{seller_id: seller_id, status: "draft"})
    %Listing{} |> Listing.creation_changeset(attrs) |> Repo.insert()
  end

  @doc "Publishes a draft listing, making it visible to buyers."
  @spec publish(Listing.t()) :: {:ok, Listing.t()} | {:error, :not_draft | Ecto.Changeset.t()}
  def publish(%Listing{status: "draft"} = listing) do
    listing |> Listing.status_changeset("published") |> Repo.update()
  end

  def publish(%Listing{}), do: {:error, :not_draft}

  @doc """
  Updates the price of a listing, recording the previous price in the
  price history table within a transaction.
  """
  @spec update_price(Listing.t(), pos_integer()) ::
          {:ok, Listing.t()} | {:error, Ecto.Changeset.t()}
  def update_price(%Listing{} = listing, new_price)
      when is_integer(new_price) and new_price > 0 do
    Repo.transaction(fn ->
      history_attrs = %{listing_id: listing.id, price_cents: listing.price_cents,
                        recorded_at: DateTime.utc_now()}
      Repo.insert!(%PriceHistory{} |> PriceHistory.changeset(history_attrs))

      case listing |> Listing.price_changeset(%{price_cents: new_price}) |> Repo.update() do
        {:ok, updated} -> updated
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  @doc "Lists published listings, optionally filtered by category or seller."
  @spec list_published(keyword()) :: [Listing.t()]
  def list_published(opts \\ []) do
    Listing
    |> where([l], l.status == "published")
    |> maybe_filter_category(Keyword.get(opts, :category_slug))
    |> maybe_filter_seller(Keyword.get(opts, :seller_id))
    |> order_by([l], desc: l.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> Repo.all()
  end

  @doc "Returns price history for a listing in chronological order."
  @spec price_history(listing_id()) :: [PriceHistory.t()]
  def price_history(listing_id) when is_binary(listing_id) do
    PriceHistory
    |> where([h], h.listing_id == ^listing_id)
    |> order_by([h], asc: h.recorded_at)
    |> Repo.all()
  end

  defp maybe_filter_category(q, nil), do: q
  defp maybe_filter_category(q, slug), do: where(q, [l], l.category_slug == ^slug)

  defp maybe_filter_seller(q, nil), do: q
  defp maybe_filter_seller(q, id), do: where(q, [l], l.seller_id == ^id)
end
```
