# Annotated Example — Speculative Assumptions

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `Fulfillment.AddressParser.parse/1`, around the line-by-line positional extraction
- **Affected function(s):** `parse/1`
- **Short explanation:** The function splits a free-form address string by newline and accesses each line by position using `Enum.at/2`. Addresses have highly variable formats (e.g., apartment numbers on the first line, two-line street addresses, missing state lines). `Enum.at/2` silently returns `nil` or the wrong line for any address that doesn't fit the assumed 4-line format, causing shipments to be created with wrong or missing address fields without any error.

---

```elixir
defmodule Fulfillment.AddressParser do
  @moduledoc """
  Parses free-form postal address strings into structured address records
  for shipment label generation and carrier API submissions.

  Expected address format (4 lines):
    Line 0: Recipient name
    Line 1: Street address
    Line 2: City, State, ZIP
    Line 3: Country
  """

  require Logger

  @country_codes ~w(BR US CA MX AR CL CO PE)

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because the function splits the address string on "\n"
  # VALIDATION: and uses Enum.at/2 with hardcoded line indices to extract each field.
  # VALIDATION: Real-world addresses vary widely: some have two street lines (apartment
  # VALIDATION: numbers, building names), some omit the country, and some compress
  # VALIDATION: the city/state/zip differently. Enum.at/2 never raises; it returns nil
  # VALIDATION: for any index beyond the list length. So a 3-line address silently
  # VALIDATION: produces a struct where `country` is nil and `city_line` may contain
  # VALIDATION: the street — all without an error. Carrier API calls then fail or,
  # VALIDATION: worse, succeed with a wrong delivery address, shipping to the incorrect
  # VALIDATION: location while the system believes everything is correct.
  def parse(raw_address) when is_binary(raw_address) do
    lines = raw_address |> String.trim() |> String.split("\n") |> Enum.map(&String.trim/1)

    recipient  = Enum.at(lines, 0)
    street     = Enum.at(lines, 1)
    city_line  = Enum.at(lines, 2)
    country    = Enum.at(lines, 3)

    {city, state, zip} = parse_city_line(city_line)

    %{
      recipient: recipient,
      street:    street,
      city:      city,
      state:     state,
      zip:       zip,
      country:   normalize_country(country)
    }
  end
  # VALIDATION: SMELL END

  def parse(_), do: {:error, :invalid_address}

  defp parse_city_line(nil), do: {nil, nil, nil}
  defp parse_city_line(line) do
    case Regex.run(~r/^(.+),\s*([A-Z]{2})\s+(\d{5}(?:-\d{4})?)$/, String.trim(line)) do
      [_, city, state, zip] -> {city, state, zip}
      _                     ->
        case Regex.run(~r/^(.+)\s+(\d{5,8})$/, String.trim(line)) do
          [_, city, zip] -> {city, nil, zip}
          _              -> {line, nil, nil}
        end
    end
  end

  defp normalize_country(nil), do: nil
  defp normalize_country(str) do
    upper = String.upcase(String.trim(str))
    if upper in @country_codes, do: upper, else: str
  end

  def validate(%{recipient: r, street: s, city: c, zip: z})
      when is_binary(r) and is_binary(s) and is_binary(c) and is_binary(z) do
    :ok
  end

  def validate(addr) do
    missing =
      [:recipient, :street, :city, :zip]
      |> Enum.reject(fn key -> is_binary(Map.get(addr, key)) end)

    {:error, {:missing_fields, missing}}
  end

  def format_label(%{recipient: r, street: s, city: c, state: st, zip: z, country: co}) do
    state_part = if st, do: ", #{st}", else: ""
    country_part = if co, do: "\n#{co}", else: ""
    "#{r}\n#{s}\n#{c}#{state_part} #{z}#{country_part}"
  end

  def to_carrier_payload(%{recipient: r, street: s, city: c, state: st, zip: z, country: co}) do
    %{
      "name"       => r,
      "address1"   => s,
      "city"       => c,
      "state"      => st,
      "postalCode" => z,
      "country"    => co || "BR"
    }
  end

  def domestic?(addr) do
    Map.get(addr, :country) in [nil, "BR"]
  end

  def requires_customs?(addr) do
    co = Map.get(addr, :country)
    is_binary(co) and co != "BR"
  end
end
```
