```elixir
defmodule Marketplace.BidContext do
  @moduledoc """
  Manages listing bids in a peer-to-peer marketplace. Buyers place bids
  on active listings; sellers accept or decline. A bid can be retracted
  by the buyer before acceptance. The context enforces business rules
  such as minimum bid increments and the prohibition of self-bidding.
  All state changes emit domain events for downstream projection.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Marketplace.{Bid, Listing}
  alias Events.Publisher

  @type listing_id :: Ecto.UUID.t()
  @type buyer_id :: String.t()
  @type bid_id :: Ecto.UUID.t()
  @type amount_cents :: pos_integer()

  @minimum_increment_cents 100

  @doc """
  Places a new bid on `listing_id` by `buyer_id` at `amount_cents`.
  Enforces that the buyer is not the listing owner, the listing is active,
  and the amount exceeds any existing bid by the minimum increment.
  """
  @spec place(listing_id(), buyer_id(), amount_cents()) ::
          {:ok, Bid.t()}
          | {:error,
             :listing_not_found
             | :listing_not_active
             | :self_bid_prohibited
             | :below_minimum_increment
             | Ecto.Changeset.t()}
  def place(listing_id, buyer_id, amount_cents)
      when is_binary(listing_id) and is_binary(buyer_id)
      and is_integer(amount_cents) and amount_cents > 0 do
    Repo.transaction(fn ->
      with {:ok, listing} <- fetch_active_listing(listing_id),
           :ok <- check_not_self_bid(listing, buyer_id),
           :ok <- check_minimum_increment(listing_id, amount_cents) do
        attrs = %{listing_id: listing_id, buyer_id: buyer_id, amount_cents: amount_cents, status: "pending"}
        case %Bid{} |> Bid.changeset(attrs) |> Repo.insert() do
          {:ok, bid} ->
            Publisher.publish(%Events.BidPlaced{
              listing_id: listing_id, bid_id: bid.id,
              buyer_id: buyer_id, amount_cents: amount_cents,
              placed_at: DateTime.utc_now()
            })
            bid

          {:error, cs} ->
            Repo.rollback(cs)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Accepts `bid_id` on behalf of the listing's seller."
  @spec accept(bid_id(), String.t()) ::
          {:ok, Bid.t()} | {:error, :not_found | :not_the_seller | :bid_not_pending}
  def accept(bid_id, seller_id) when is_binary(bid_id) and is_binary(seller_id) do
    with {:ok, bid} <- fetch_bid(bid_id),
         {:ok, _listing} <- verify_seller(bid.listing_id, seller_id),
         :ok <- check_bid_pending(bid) do
      bid |> Bid.status_changeset("accepted") |> Repo.update()
    end
  end

  @doc "Retracts a pending bid. Only the placing buyer may retract."
  @spec retract(bid_id(), buyer_id()) ::
          {:ok, Bid.t()} | {:error, :not_found | :not_the_buyer | :bid_not_pending}
  def retract(bid_id, buyer_id) when is_binary(bid_id) and is_binary(buyer_id) do
    with {:ok, %Bid{buyer_id: ^buyer_id} = bid} <- fetch_bid(bid_id),
         :ok <- check_bid_pending(bid) do
      bid |> Bid.status_changeset("retracted") |> Repo.update()
    else
      {:ok, %Bid{}} -> {:error, :not_the_buyer}
      err -> err
    end
  end

  @doc "Returns all bids for a listing sorted by amount descending."
  @spec bids_for(listing_id()) :: [Bid.t()]
  def bids_for(listing_id) when is_binary(listing_id) do
    Bid
    |> where([b], b.listing_id == ^listing_id)
    |> order_by([b], desc: b.amount_cents)
    |> Repo.all()
  end

  defp fetch_active_listing(listing_id) do
    case Repo.get(Listing, listing_id) do
      nil -> {:error, :listing_not_found}
      %Listing{status: "active"} = l -> {:ok, l}
      %Listing{} -> {:error, :listing_not_active}
    end
  end

  defp check_not_self_bid(%Listing{seller_id: seller_id}, buyer_id) do
    if seller_id == buyer_id, do: {:error, :self_bid_prohibited}, else: :ok
  end

  defp check_minimum_increment(listing_id, amount_cents) do
    max_bid =
      from(b in Bid, where: b.listing_id == ^listing_id and b.status == "pending",
        select: max(b.amount_cents))
      |> Repo.one()
      |> Kernel.||(0)

    if amount_cents >= max_bid + @minimum_increment_cents, do: :ok,
      else: {:error, :below_minimum_increment}
  end

  defp fetch_bid(bid_id) do
    case Repo.get(Bid, bid_id) do
      nil -> {:error, :not_found}
      bid -> {:ok, bid}
    end
  end

  defp verify_seller(listing_id, seller_id) do
    case Repo.get(Listing, listing_id) do
      %Listing{seller_id: ^seller_id} = l -> {:ok, l}
      %Listing{} -> {:error, :not_the_seller}
      nil -> {:error, :not_found}
    end
  end

  defp check_bid_pending(%Bid{status: "pending"}), do: :ok
  defp check_bid_pending(%Bid{}), do: {:error, :bid_not_pending}
end
```
