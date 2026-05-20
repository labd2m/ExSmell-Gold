```elixir
defmodule MarketplaceAction do
  @moduledoc """
  Orchestrates key marketplace actions including product listing creation
  by sellers, offer submissions by buyers, and dispute filing for
  transactions that did not meet expectations.
  """

  alias MarketplaceAction.{
    ListingCreation,
    OfferSubmission,
    DisputeFiling,
    ListingStore,
    OfferStore,
    DisputeStore,
    PricingValidator,
    ContentModerator,
    TransactionStore,
    SellerNotifier,
    BuyerNotifier,
    TrustSafety
  }

  require Logger

  @doc """
  Perform a marketplace action.

  Accepts a `%ListingCreation{}`, `%OfferSubmission{}`, or `%DisputeFiling{}`
  and executes the corresponding marketplace workflow.

  ## Examples

      iex> MarketplaceAction.perform(%ListingCreation{seller_id: 1, title: "Vintage Chair", price: 150_00})
      {:ok, %Listing{id: "lst_001", status: :active}}

  """
  def perform(%ListingCreation{
        seller_id: seller_id,
        title: title,
        description: description,
        price: price,
        category: category,
        condition: condition,
        images: images,
        shipping_options: shipping_options
      }) do
    with :ok <- ContentModerator.screen_listing(title, description, images),
         :ok <- PricingValidator.validate(price, category),
         {:ok, listing} <-
           ListingStore.create(%{
             seller_id: seller_id,
             title: title,
             description: description,
             price: price,
             category: category,
             condition: condition,
             images: images,
             shipping_options: shipping_options,
             status: :active,
             listed_at: DateTime.utc_now()
           }),
         :ok <- SellerNotifier.send_listing_live(seller_id, listing) do
      Logger.info("Listing #{listing.id} created by seller #{seller_id}")
      {:ok, listing}
    end
  end

  # perform buyer offer submission on an active listing
  def perform(%OfferSubmission{
        buyer_id: buyer_id,
        listing_id: listing_id,
        offered_price: offered_price,
        message: message,
        expires_in_hours: expires_in
      })
      when offered_price > 0 do
    with {:ok, listing} <- ListingStore.find(listing_id),
         :ok <- validate_listing_purchasable(listing),
         :ok <- validate_offer_reasonable(offered_price, listing.price),
         expires_at = DateTime.add(DateTime.utc_now(), expires_in * 3600, :second),
         {:ok, offer} <-
           OfferStore.create(%{
             buyer_id: buyer_id,
             listing_id: listing_id,
             seller_id: listing.seller_id,
             offered_price: offered_price,
             message: message,
             expires_at: expires_at,
             status: :pending
           }),
         :ok <- SellerNotifier.send_offer_received(listing.seller_id, offer, listing) do
      Logger.info("Offer #{offer.id} submitted by buyer #{buyer_id} on listing #{listing_id}")
      {:ok, offer}
    end
  end

  # perform dispute filing for a completed or in-progress transaction
  def perform(%DisputeFiling{
        transaction_id: txn_id,
        filed_by: user_id,
        reason: reason,
        description: description,
        evidence_urls: evidence_urls
      })
      when reason in [:item_not_received, :item_not_as_described, :unauthorized_charge, :seller_fraud] do
    with {:ok, transaction} <- TransactionStore.find(txn_id),
         :ok <- validate_dispute_eligible(transaction, user_id),
         :ok <- TrustSafety.screen_dispute_filer(user_id),
         {:ok, dispute} <-
           DisputeStore.create(%{
             transaction_id: txn_id,
             filed_by: user_id,
             reason: reason,
             description: description,
             evidence_urls: evidence_urls,
             status: :open,
             filed_at: DateTime.utc_now()
           }),
         other_party_id = if(transaction.buyer_id == user_id, do: transaction.seller_id, else: transaction.buyer_id),
         :ok <- BuyerNotifier.send_dispute_opened(other_party_id, dispute, transaction) do
      Logger.warning("Dispute #{dispute.id} filed by user #{user_id} on transaction #{txn_id}: #{reason}")
      {:ok, dispute}
    end
  end

  defp validate_listing_purchasable(%{status: :active}), do: :ok
  defp validate_listing_purchasable(%{status: s}), do: {:error, {:listing_not_active, s}}

  defp validate_offer_reasonable(offered_price, listing_price) do
    ratio = offered_price / listing_price
    if ratio >= 0.5, do: :ok, else: {:error, :offer_too_low}
  end

  defp validate_dispute_eligible(transaction, user_id) do
    cond do
      transaction.buyer_id != user_id and transaction.seller_id != user_id ->
        {:error, :not_a_party_to_transaction}

      transaction.status not in [:completed, :in_progress] ->
        {:error, {:transaction_not_disputable, transaction.status}}

      Date.diff(Date.utc_today(), DateTime.to_date(transaction.completed_at || DateTime.utc_now())) > 45 ->
        {:error, :dispute_window_expired}

      true ->
        :ok
    end
  end
end
```
