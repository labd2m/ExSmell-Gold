# Annotated Example 32

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `AddressValidator.validate/1` (library) and `CheckoutFlow.confirm_address/2` (client)
- **Affected function(s):** `AddressValidator.validate/1`, `CheckoutFlow.confirm_address/2`
- **Short explanation:** `AddressValidator.validate/1` raises exceptions for undeliverable postcodes, unsupported countries, and missing required fields. These outcomes arise constantly during checkout when customers enter incomplete or invalid shipping addresses. Without a tuple-based alternative, `CheckoutFlow.confirm_address/2` is forced to use `try...rescue` for what is routine input validation.

```elixir
defmodule AddressValidator do
  @moduledoc """
  Validates shipping addresses against carrier delivery zones
  and required field rules for international and domestic shipments.
  """

  defmodule MissingFieldError do
    defexception [:message, :missing_fields]
  end

  defmodule UndeliverablePostcodeError do
    defexception [:message, :postcode, :country_code]
  end

  defmodule UnsupportedCountryError do
    defexception [:message, :country_code]
  end

  defmodule InvalidPostcodeFormatError do
    defexception [:message, :postcode, :country_code]
  end

  @supported_countries ~w(US CA GB AU DE FR NL SE NO)
  @required_fields ~w(line1 city country_code postcode)a

  @po_box_regex ~r/\b(P\.?O\.?\s*Box|Post\s*Office\s*Box)\b/i
  @us_postcode_regex ~r/^\d{5}(-\d{4})?$/
  @uk_postcode_regex ~r/^[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}$/i
  @undeliverable_us_postcodes MapSet.new(~w(99999 00000 12345))

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because bad postcodes, unsupported countries,
  # and missing fields are standard outcomes of user-entered address data during
  # checkout. Exposing them only as exceptions means every checkout confirmation
  # step must use try...rescue instead of a cleaner pattern-match on
  # {:ok, _}/{:error, _}.
  def validate(address) do
    missing =
      @required_fields
      |> Enum.reject(&(Map.has_key?(address, &1) and not is_nil(Map.get(address, &1)) and Map.get(address, &1) != ""))

    unless missing == [] do
      raise MissingFieldError,
        message: "Address is missing required fields: #{inspect(missing)}",
        missing_fields: missing
    end

    country_code = address.country_code

    unless country_code in @supported_countries do
      raise UnsupportedCountryError,
        message: "Shipping to '#{country_code}' is not currently supported",
        country_code: country_code
    end

    postcode = address.postcode
    validate_postcode_format!(postcode, country_code)
    check_deliverability!(postcode, country_code)

    if Regex.match?(@po_box_regex, address.line1) do
      raise UndeliverablePostcodeError,
        message: "PO Box addresses cannot be used for courier deliveries",
        postcode: postcode,
        country_code: country_code
    end

    %{
      normalised: %{
        line1: String.trim(address.line1),
        line2: Map.get(address, :line2),
        city: String.trim(address.city),
        state: Map.get(address, :state),
        postcode: String.upcase(String.trim(postcode)),
        country_code: country_code
      },
      deliverable: true,
      validated_at: DateTime.utc_now()
    }
  end
  # VALIDATION: SMELL END

  defp validate_postcode_format!(postcode, "US") do
    unless Regex.match?(@us_postcode_regex, postcode) do
      raise InvalidPostcodeFormatError,
        message: "US ZIP code '#{postcode}' is not in a valid format (NNNNN or NNNNN-NNNN)",
        postcode: postcode,
        country_code: "US"
    end
  end

  defp validate_postcode_format!(postcode, "GB") do
    unless Regex.match?(@uk_postcode_regex, postcode) do
      raise InvalidPostcodeFormatError,
        message: "UK postcode '#{postcode}' is not in a recognised format",
        postcode: postcode,
        country_code: "GB"
    end
  end

  defp validate_postcode_format!(_postcode, _country), do: :ok

  defp check_deliverability!(postcode, "US") do
    if MapSet.member?(@undeliverable_us_postcodes, postcode) do
      raise UndeliverablePostcodeError,
        message: "ZIP code '#{postcode}' is not deliverable",
        postcode: postcode,
        country_code: "US"
    end
  end

  defp check_deliverability!(_postcode, _country), do: :ok
end

defmodule CheckoutFlow do
  @moduledoc """
  Handles shipping address confirmation during the checkout process.
  """

  require Logger

  def confirm_address(order_id, raw_address) do
    Logger.info("Validating shipping address for order #{order_id}")

    # VALIDATION: SMELL START - Using exceptions for control-flow
    # VALIDATION: This is a smell because invalid addresses are a constant,
    # expected part of checkout flows. The client is forced to use try...rescue
    # for every address submission because AddressValidator provides no way
    # to receive a structured error tuple instead.
    try do
      result = AddressValidator.validate(raw_address)
      Logger.info("Address validated for order #{order_id}")
      {:ok, result.normalised}
    rescue
      e in AddressValidator.MissingFieldError ->
        Logger.debug("Address for order #{order_id} missing fields: #{inspect(e.missing_fields)}")
        {:error, :missing_fields, e.missing_fields}

      e in AddressValidator.UnsupportedCountryError ->
        Logger.info("Unsupported country #{e.country_code} for order #{order_id}")
        {:error, :unsupported_country, e.country_code}

      e in AddressValidator.InvalidPostcodeFormatError ->
        Logger.debug("Bad postcode '#{e.postcode}' (#{e.country_code}) for order #{order_id}")
        {:error, :invalid_postcode, e.postcode}

      e in AddressValidator.UndeliverablePostcodeError ->
        Logger.info("Undeliverable address for order #{order_id}: #{e.postcode}")
        {:error, :undeliverable, e.postcode}
    end
    # VALIDATION: SMELL END
  end
end
```
