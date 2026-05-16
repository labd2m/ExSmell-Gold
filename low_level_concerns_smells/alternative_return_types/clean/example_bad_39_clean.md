```elixir
defmodule Logistics.AddressValidator do
  @moduledoc """
  Validates and normalizes postal addresses using an external geocoding service.
  Supports lightweight boolean checks, strict changeset-style validation,
  and full address enrichment with suggestions.
  """

  alias Logistics.GeocoderClient
  alias Logistics.Schema.Address

  @required_fields [:street, :city, :country_code]

  @doc """
  Validates a raw address map.

  ## Options

    * `:strict` — When `true`, returns `{:ok, %Address{}}` on success or
      `{:error, [reason]}` on failure, rather than a boolean. Defaults to `false`.
    * `:enrich` — When `true`, calls the geocoder API and returns a rich map:
      `%{valid: boolean, normalized: map, suggestions: [map], coordinates: map | nil}`.
      Takes precedence over `:strict`.

  ## Examples

      iex> validate(%{street: "123 Main St", city: "Springfield", country_code: "US"})
      true

      iex> validate(%{street: "", city: "Springfield", country_code: "US"})
      false

      iex> validate(%{street: "123 Main St", city: "Springfield", country_code: "US"}, strict: true)
      {:ok, %Address{street: "123 Main St", city: "Springfield", country_code: "US"}}

      iex> validate(%{street: "", city: nil, country_code: "US"}, strict: true)
      {:error, [:street_blank, :city_missing]}

      iex> validate(%{street: "123 Main St", city: "Sprigfield", country_code: "US"}, enrich: true)
      %{valid: true, normalized: %{...}, suggestions: [], coordinates: %{lat: 39.8, lng: -89.6}}

  """

  def validate(address_attrs, opts \\ []) when is_map(address_attrs) and is_list(opts) do
    errors = collect_errors(address_attrs)

    cond do
      opts[:enrich] == true ->
        case GeocoderClient.lookup(address_attrs) do
          {:ok, geocoded} ->
            %{
              valid: errors == [],
              normalized: geocoded.normalized_address,
              suggestions: geocoded.suggestions,
              coordinates: %{lat: geocoded.lat, lng: geocoded.lng}
            }

          {:error, _} ->
            %{
              valid: errors == [],
              normalized: address_attrs,
              suggestions: [],
              coordinates: nil
            }
        end

      opts[:strict] == true ->
        if errors == [] do
          struct = struct(Address, address_attrs)
          {:ok, struct}
        else
          {:error, errors}
        end

      true ->
        errors == []
    end
  end

  defp collect_errors(attrs) do
    Enum.flat_map(@required_fields, fn field ->
      value = Map.get(attrs, field)

      cond do
        is_nil(value) -> [:"#{field}_missing"]
        is_binary(value) and String.trim(value) == "" -> [:"#{field}_blank"]
        true -> []
      end
    end) ++ validate_country_code(Map.get(attrs, :country_code))
  end

  defp validate_country_code(nil), do: []

  defp validate_country_code(code) when is_binary(code) do
    if String.match?(code, ~r/^[A-Z]{2}$/) do
      []
    else
      [:invalid_country_code]
    end
  end

  defp validate_country_code(_), do: [:invalid_country_code]

  @doc """
  Normalizes a country code to its ISO 3166-1 alpha-2 form.
  """
  def normalize_country_code(code) when is_binary(code) do
    code |> String.trim() |> String.upcase()
  end

  @doc """
  Returns a list of supported country codes.
  """
  def supported_countries do
    ~w(US CA GB AU DE FR NL SE NO DK FI PL BR MX AR)
  end
end
```
