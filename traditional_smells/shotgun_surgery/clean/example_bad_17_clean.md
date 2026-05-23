```elixir
defmodule RealEstate.ListingManager do
  @moduledoc """
  Handles real estate listing creation and management including
  commission calculation, listing duration policies, tier assignment,
  and required legal disclosures for different types of property listings.
  """

  alias RealEstate.{
    Listing, AgentRegistry, DisclosureEngine,
    ListingPortal, ComplianceChecker, AuditLog
  }

  def publish_listing(agent_id, property, listing_type, asking_price) do
    with {:ok, agent}   <- AgentRegistry.fetch(agent_id),
         {:ok, listing} <- create_listing(agent, property, listing_type, asking_price),
         :ok            <- ComplianceChecker.verify(listing),
         :ok            <- ListingPortal.publish(listing),
         :ok            <- AuditLog.record_published(agent_id, listing.id) do
      {:ok, listing}
    end
  end

  defp create_listing(agent, property, listing_type, asking_price) do
    commission  = calculate_agent_commission(asking_price, listing_type)
    expires_at  = Date.add(Date.utc_today(), get_listing_duration_days(listing_type))
    tier        = assign_listing_tier(listing_type)
    disclosures = get_required_disclosures(listing_type)

    listing = %Listing{
      agent_id:           agent.id,
      property_id:        property.id,
      listing_type:       listing_type,
      asking_price:       asking_price,
      agent_commission:   commission,
      tier:               tier,
      expires_at:         expires_at,
      required_disclosures: disclosures,
      pending_disclosures:  disclosures,
      status:             :draft
    }

    Listing.insert(listing)
  end

  def renew_listing(%Listing{} = listing) do
    new_expiry = Date.add(Date.utc_today(), get_listing_duration_days(listing.listing_type))
    updated = %{listing | expires_at: new_expiry, status: :active}
    with {:ok, saved} <- Listing.update(updated) do
      AuditLog.record_renewed(listing.agent_id, listing.id)
      {:ok, saved}
    end
  end

  def close_listing(%Listing{} = listing, sale_price) do
    commission = calculate_agent_commission(sale_price, listing.listing_type)
    updated = %{listing | status: :sold, final_price: sale_price, final_commission: commission}
    with {:ok, saved} <- Listing.update(updated) do
      AgentRegistry.credit_commission(listing.agent_id, commission)
      {:ok, saved}
    end
  end

  def calculate_agent_commission(price, :sale) do
    Float.round(price * 0.03, 2)
  end

  def calculate_agent_commission(price, :rental) do
    monthly_rent = price
    Float.round(monthly_rent * 0.50, 2)
  end

  def calculate_agent_commission(price, :auction) do
    Float.round(price * 0.025, 2)
  end

  def calculate_agent_commission(price, _type) do
    Float.round(price * 0.02, 2)
  end

  def get_listing_duration_days(:sale),    do: 90
  def get_listing_duration_days(:rental),  do: 30
  def get_listing_duration_days(:auction), do: 14
  def get_listing_duration_days(_),        do: 60

  def assign_listing_tier(:sale),    do: :standard
  def assign_listing_tier(:rental),  do: :featured
  def assign_listing_tier(:auction), do: :premium
  def assign_listing_tier(_),        do: :basic

  def get_required_disclosures(:sale) do
    [:sellers_disclosure, :lead_paint_disclosure, :hoa_documents, :title_report]
  end

  def get_required_disclosures(:rental) do
    [:habitability_certification, :move_in_inspection, :utility_disclosures]
  end

  def get_required_disclosures(:auction) do
    [:auction_terms, :reserve_price_disclosure, :as_is_disclaimer, :title_report]
  end

  def get_required_disclosures(_) do
    [:basic_property_disclosure]
  end

  def submit_disclosure(%Listing{} = listing, disclosure_type, document) do
    if disclosure_type in listing.pending_disclosures do
      DisclosureEngine.save(listing.id, disclosure_type, document)
      updated = %{listing | pending_disclosures: List.delete(listing.pending_disclosures, disclosure_type)}

      if updated.pending_disclosures == [] do
        Listing.update(%{updated | disclosure_status: :complete})
      else
        Listing.update(updated)
      end
    else
      {:error, :disclosure_not_required}
    end
  end

  def list_listing_types, do: [:sale, :rental, :auction]
end
```
