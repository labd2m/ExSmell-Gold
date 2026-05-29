# Annotated Example — Code Smell: Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `RealEstate.ListingPublisher.publish/2`
- **Affected function(s):** `publish/2`
- **Short explanation:** `publish/2` combines content-completeness validation, photo processing, geolocation enrichment, valuation estimation, syndication to multiple portals, social-media post generation, agent notification, and audit logging inside one long function body.

---

```elixir
defmodule RealEstate.ListingPublisher do
  @moduledoc """
  Publishes property listings to the platform and external
  portal syndications with enrichment and media processing.
  """

  require Logger

  alias RealEstate.{
    Listing, Photo, Geocoder, Valuator,
    PortalSyndicator, SocialPoster, AgentMailer, AuditLog
  }

  @required_fields  ~w(title address price_cents bedrooms bathrooms sqft)a
  @max_photos       30
  @portals          [:zillow, :realtor_com, :trulia]

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `publish/2` handles field-
  # completeness checking, minimum-photo enforcement, image transcoding,
  # geocoding, automated valuation, multi-portal syndication, social-post
  # generation, agent-email notification, and audit recording — all inlined
  # in one function body of over 110 lines with no single-purpose helpers.
  def publish(%Listing{} = listing, opts \\ []) do
    publisher  = Keyword.get(opts, :published_by, "system")
    skip_socials = Keyword.get(opts, :skip_social_posts, false)

    # 1. Validate required fields
    missing_fields =
      Enum.filter(@required_fields, fn field ->
        value = Map.get(listing, field)
        is_nil(value) or value == "" or value == 0
      end)

    if missing_fields != [] do
      {:error, {:missing_required_fields, missing_fields}}
    else
      # 2. Check photo count
      photos = Photo.list_for_listing(listing.id)

      cond do
        length(photos) < 3 ->
          {:error, :insufficient_photos}

        length(photos) > @max_photos ->
          {:error, {:too_many_photos, length(photos)}}

        true ->
          # 3. Process and optimise photos
          processed_photos =
            Enum.map(photos, fn photo ->
              case Photo.transcode(photo.id, formats: [:webp, :jpeg], widths: [800, 1600]) do
                {:ok, transcoded} -> transcoded
                {:error, reason}  ->
                  Logger.warning("Photo transcode failed #{photo.id}: #{inspect(reason)}")
                  photo
              end
            end)

          cover_photo = List.first(processed_photos)

          # 4. Geocode the address
          geo =
            case Geocoder.geocode(listing.address) do
              {:ok, coords} ->
                coords

              {:error, reason} ->
                Logger.warning("Geocoding failed: #{inspect(reason)}")
                nil
            end

          listing =
            if geo do
              %{listing | latitude: geo.lat, longitude: geo.lng,
                          neighbourhood: geo.neighbourhood, city: geo.city}
            else
              listing
            end

          # 5. Automated valuation
          estimated_value =
            case Valuator.estimate(%{
              address:    listing.address,
              sqft:       listing.sqft,
              bedrooms:   listing.bedrooms,
              bathrooms:  listing.bathrooms,
              year_built: listing.year_built
            }) do
              {:ok, val}       -> val.estimate_cents
              {:error, _reason} -> nil
            end

          listing = %{listing | estimated_value_cents: estimated_value}

          # 6. Mark listing as published
          case Listing.update(listing.id, %{
            status:           :active,
            published_at:     DateTime.utc_now(),
            published_by:     publisher,
            cover_photo_url:  cover_photo && cover_photo.url
          }) do
            {:error, reason} ->
              Logger.error("Listing update failed #{listing.id}: #{inspect(reason)}")
              {:error, :update_failed}

            {:ok, published_listing} ->
              # 7. Syndicate to external portals
              syndication_results =
                Enum.map(@portals, fn portal ->
                  case PortalSyndicator.sync(portal, published_listing) do
                    {:ok, ext_id} ->
                      Logger.info("Synced to #{portal}: #{ext_id}")
                      {:ok, portal, ext_id}

                    {:error, reason} ->
                      Logger.warning("Syndication to #{portal} failed: #{inspect(reason)}")
                      {:error, portal}
                  end
                end)

              synced_count = Enum.count(syndication_results, &match?({:ok, _, _}, &1))
              Logger.info("#{synced_count}/#{length(@portals)} portals synced for listing #{listing.id}")

              # 8. Generate social media post
              unless skip_socials do
                post_text = """
                🏠 New listing! #{listing.bedrooms}BR / #{listing.bathrooms}BA in #{listing.city}
                Price: $#{div(listing.price_cents, 100) |> Number.Delimit.number_to_delimited()}
                #{listing.sqft} sq ft · #{listing.address}
                See details: https://example.com/listings/#{listing.slug}
                """

                case SocialPoster.post(:instagram, post_text, image_url: cover_photo && cover_photo.url) do
                  {:ok, _}         -> :ok
                  {:error, reason} -> Logger.warning("Social post failed: #{inspect(reason)}")
                end
              end

              # 9. Notify the listing agent
              agent_email_body = """
              Hi #{listing.agent_name},

              Your listing "#{listing.title}" is now live!

              Address  : #{listing.address}
              Price    : $#{div(listing.price_cents, 100)}
              Portals  : #{synced_count} of #{length(@portals)} synced

              View it at: https://example.com/listings/#{listing.slug}
              """

              case AgentMailer.notify(listing.agent_email, "Listing Published", agent_email_body) do
                {:ok, _}         -> :ok
                {:error, reason} -> Logger.warning("Agent notification failed: #{inspect(reason)}")
              end

              # 10. Audit log
              AuditLog.insert(%AuditLog{
                action:     "listing_published",
                entity:     "listing",
                entity_id:  listing.id,
                actor:      publisher,
                metadata:   %{portals: synced_count, photos: length(processed_photos)},
                inserted_at: DateTime.utc_now()
              })

              {:ok, published_listing}
          end
      end
    end
  end
  # VALIDATION: SMELL END
end
```
