# Code Smell Example — Annotated

## Metadata

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `Geo.AddressValidator.validate/1`
- **Affected function(s):** `Geo.AddressValidator.validate/1` (library side); `Geo.CheckoutAddressVerifier.verify_shipping_address/1` (client side)
- **Explanation:** `validate/1` raises `RuntimeError` for ordinary address-validation failures: missing required fields, unsupported country, and unresolvable postal code. During checkout or user registration, invalid addresses are commonplace inputs. Callers can only determine why an address was rejected by catching a `RuntimeError`, which forces exception-based control-flow for a routine validation concern.

```elixir
defmodule Geo.Address do
  @moduledoc "Represents an address submitted by a user."

  @enforce_keys [:line1, :city, :country_code]
  defstruct [
    :line1,
    :line2,
    :city,
    :state_or_province,
    :postal_code,
    :country_code
  ]
end

defmodule Geo.CountryRegistry do
  @moduledoc "List of countries we support for shipping and billing."

  @supported %{
    "US" => %{requires_state: true, postal_regex: ~r/^\d{5}(-\d{4})?$/},
    "CA" => %{requires_state: true, postal_regex: ~r/^[A-Z]\d[A-Z] \d[A-Z]\d$/i},
    "GB" => %{requires_state: false, postal_regex: ~r/^[A-Z]{1,2}\d[A-Z\d]? \d[A-Z]{2}$/i},
    "BR" => %{requires_state: true, postal_regex: ~r/^\d{5}-\d{3}$/},
    "DE" => %{requires_state: false, postal_regex: ~r/^\d{5}$/},
    "AU" => %{requires_state: true, postal_regex: ~r/^\d{4}$/}
  }

  def find(code), do: Map.fetch(@supported, code)
  def supported?(code), do: Map.has_key?(@supported, code)
  def all_codes, do: Map.keys(@supported)
end

defmodule Geo.PostalResolver do
  @moduledoc "Simulates a postal code geocoding lookup."

  @unresolvable ~w[00000 99999 INVALID]

  def resolve(postal_code) do
    if postal_code in @unresolvable do
      {:error, :unresolvable}
    else
      {:ok, %{lat: 40.7128, lng: -74.0060, city: "New York", region: "NY"}}
    end
  end
end

defmodule Geo.AddressValidator do
  @moduledoc """
  Validates address structs for completeness, country support, postal code format,
  and geocodability. Used during checkout and user registration flows.
  """

  alias Geo.{Address, CountryRegistry, PostalResolver}
  require Logger

  @required_fields [:line1, :city, :country_code, :postal_code]

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because `validate/1` raises RuntimeError for four
  # VALIDATION: expected address validation outcomes: missing required field,
  # VALIDATION: unsupported country, postal code format mismatch, and an
  # VALIDATION: unresolvable postal code. These are all ordinary user-input problems,
  # VALIDATION: not system-level crashes. Callers at checkout cannot pattern-match
  # VALIDATION: on a result tuple — they must rescue a RuntimeError to discover
  # VALIDATION: why an address was rejected.
  def validate(%Address{} = address) do
    Enum.each(@required_fields, fn field ->
      value = Map.get(address, field)

      if is_nil(value) or (is_binary(value) and String.trim(value) == "") do
        raise RuntimeError,
          message: "Address is missing required field '#{field}'"
      end
    end)

    country_code = String.upcase(address.country_code)

    case CountryRegistry.find(country_code) do
      :error ->
        raise RuntimeError,
          message:
            "Country '#{country_code}' is not supported for delivery. " <>
              "Supported countries: #{Enum.join(CountryRegistry.all_codes(), ", ")}"

      {:ok, country} ->
        postal = String.trim(address.postal_code)

        unless String.match?(postal, country.postal_regex) do
          raise RuntimeError,
            message:
              "Postal code '#{postal}' is not valid for country '#{country_code}'"
        end

        if country.requires_state and
             (is_nil(address.state_or_province) or
                String.trim(address.state_or_province || "") == "") do
          raise RuntimeError,
            message: "State or province is required for addresses in #{country_code}"
        end

        case PostalResolver.resolve(postal) do
          {:error, :unresolvable} ->
            raise RuntimeError,
              message:
                "Postal code '#{postal}' could not be resolved to a known location"

          {:ok, geo} ->
            Logger.debug("Address validated and geocoded: #{inspect(geo)}")
            %{address: address, geo: geo, country_code: country_code}
        end
    end
  end
  # VALIDATION: SMELL END
end

defmodule Geo.CheckoutAddressVerifier do
  @moduledoc """
  Used by the checkout flow to verify that a shipping address is deliverable
  before allowing the customer to proceed to payment.
  """

  alias Geo.{Address, AddressValidator}
  require Logger

  def verify_shipping_address(%Address{} = address) do
    # Client forced to use try/rescue because AddressValidator.validate/1 raises
    # on all validation failures instead of returning {:error, reason}.
    try do
      result = AddressValidator.validate(address)

      {:ok,
       %{
         valid: true,
         normalised_address: result.address,
         geo: result.geo
       }}
    rescue
      e in RuntimeError ->
        Logger.info("Shipping address rejected: #{e.message}")

        {:error,
         %{
           valid: false,
           reason: e.message
         }}
    end
  end

  def verify_multiple(addresses) when is_list(addresses) do
    Enum.map(addresses, fn addr ->
      %{address: addr, result: verify_shipping_address(addr)}
    end)
  end
end
```
