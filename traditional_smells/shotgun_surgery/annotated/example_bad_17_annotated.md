# Example Bad 17 — Annotated

## Metadata

- **Smell Name**: Shotgun Surgery
- **Expected Smell Location**: Functions `calculate_agent_commission/2`, `get_listing_duration_days/1`, `assign_listing_tier/1`, and `get_required_disclosures/1` inside `RealEstate.ListingManager`
- **Affected Functions**: `calculate_agent_commission/2`, `get_listing_duration_days/1`, `assign_listing_tier/1`, `get_required_disclosures/1`
- **Explanation**: The real estate listing type logic (`:sale`, `:rental`, `:auction`) is distributed across four functions. Adding a new listing type (e.g., `:lease_to_own`) demands four independent changes in different parts of the module, a classic Shotgun Surgery smell.

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

  # VALIDATION: SMELL START - Shotgun Surgery [location 1 of 4]
  # VALIDATION: This is a smell because adding a new listing type (e.g., :lease_to_own)
  # requires a new clause here AND in get_listing_duration_days/1, assign_listing_tier/1,
  # and get_required_disclosures/1 — four scattered changes for one new listing type.
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
  # VALIDATION: SMELL END [location 1 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 2 of 4]
  # VALIDATION: This is a smell because a new listing type also requires a duration
  # clause here, independent of calculate_agent_commission/2.
  def get_listing_duration_days(:sale),    do: 90
  def get_listing_duration_days(:rental),  do: 30
  def get_listing_duration_days(:auction), do: 14
  def get_listing_duration_days(_),        do: 60
  # VALIDATION: SMELL END [location 2 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 3 of 4]
  # VALIDATION: This is a smell because a new listing type also requires a tier
  # assignment clause here, independent of the previous two locations.
  def assign_listing_tier(:sale),    do: :standard
  def assign_listing_tier(:rental),  do: :featured
  def assign_listing_tier(:auction), do: :premium
  def assign_listing_tier(_),        do: :basic
  # VALIDATION: SMELL END [location 3 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 4 of 4]
  # VALIDATION: This is a smell because a new listing type also requires a disclosures
  # clause here, completing the four-location change for every new listing type.
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
  # VALIDATION: SMELL END [location 4 of 4]

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
