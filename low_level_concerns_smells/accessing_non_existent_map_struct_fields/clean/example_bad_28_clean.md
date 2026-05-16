```elixir
defmodule RealEstate.ListingPublisher do
  @moduledoc """
  Validates, enriches, and publishes real-estate property listings to
  the search index. Handles residential and commercial property types,
  computes price-per-sqm metrics, and prepares geo-coordinates for
  spatial indexing.
  """

  require Logger

  @valid_property_types ~w(apartment house commercial land garage)
  @min_price            1_000.0
  @max_area_sqm         500_000.0

  @type listing_record :: %{
          id: String.t(),
          title: String.t(),
          property_type: String.t(),
          price: float(),
          area_sqm: float(),
          price_per_sqm: float() | nil,
          geo: %{lat: float(), lng: float()} | nil,
          indexed_at: DateTime.t(),
          status: :active | :pending_geo
        }

  @spec publish(map(), map()) ::
          {:ok, listing_record()} | {:error, list(String.t())}
  def publish(listing, publisher_config) do
    price         = listing[:price]
    property_type = listing[:property_type]
    area_sqm      = listing[:area_sqm]
    geo           = listing[:geo]

    errors =
      []
      |> validate_price(price)
      |> validate_property_type(property_type)
      |> validate_area(area_sqm)
      |> validate_geo(geo)

    if errors == [] do
      price_per_sqm =
        if area_sqm && area_sqm > 0 do
          compute_price_per_sqm(price, area_sqm)
        end

      {status, indexed_geo} = resolve_geo(geo, publisher_config)

      record = %{
        id: Map.fetch!(listing, :id),
        title: Map.get(listing, :title, "Untitled Listing"),
        property_type: property_type,
        price: price,
        area_sqm: area_sqm,
        price_per_sqm: price_per_sqm,
        geo: indexed_geo,
        indexed_at: DateTime.utc_now(),
        status: status
      }

      emit_to_index(record, publisher_config)

      Logger.info("Listing published",
        listing_id: record.id,
        property_type: property_type,
        price: price,
        status: status,
        has_geo: not is_nil(indexed_geo)
      )

      {:ok, record}
    else
      {:error, errors}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp compute_price_per_sqm(price, area_sqm) do
    Float.round(price / area_sqm, 2)
  end

  defp resolve_geo(nil, _config) do
    Logger.warning("Listing published without geo-coordinates; spatial indexing skipped")
    {:pending_geo, nil}
  end

  defp resolve_geo(%{lat: lat, lng: lng} = geo, _config)
       when is_float(lat) and is_float(lng) do
    {:active, geo}
  end

  defp resolve_geo(_, _config), do: {:pending_geo, nil}

  defp emit_to_index(record, config) do
    index_name = Map.get(config, :index_name, "listings")
    Logger.debug("Emitting listing #{record.id} to index '#{index_name}'")
    :ok
  end

  # ── Validators ──────────────────────────────────────────────────────────────

  defp validate_price(errors, nil),
    do: ["Price is required" | errors]

  defp validate_price(errors, price) when is_number(price) and price >= @min_price,
    do: errors

  defp validate_price(errors, price),
    do: ["Price must be at least #{@min_price}, got: #{inspect(price)}" | errors]

  defp validate_property_type(errors, nil),
    do: ["Property type is required" | errors]

  defp validate_property_type(errors, t) when t in @valid_property_types,
    do: errors

  defp validate_property_type(errors, t),
    do: ["Invalid property type: #{t}" | errors]

  defp validate_area(errors, nil),
    do: ["Area (sqm) is required" | errors]

  defp validate_area(errors, a) when is_number(a) and a > 0 and a <= @max_area_sqm,
    do: errors

  defp validate_area(errors, a),
    do: ["Area must be between 0 and #{@max_area_sqm} sqm, got: #{inspect(a)}" | errors]

  defp validate_geo(errors, nil),   do: errors
  defp validate_geo(errors, %{lat: lat, lng: lng})
       when is_float(lat) and is_float(lng),
       do: errors

  defp validate_geo(errors, geo),
    do: ["Invalid geo coordinates: #{inspect(geo)}" | errors]
end
```
