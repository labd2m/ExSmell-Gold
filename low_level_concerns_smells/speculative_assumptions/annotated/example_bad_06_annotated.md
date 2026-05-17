# Annotated Example — Speculative Assumptions

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `extract_country_code/1` function, lines ~38–58
- **Affected function(s):** `extract_country_code/1`
- **Short explanation:** `extract_country_code/1` uses a series of heuristics to guess a country code from a phone number string. When all heuristics fail it returns `"XX"` — a fake placeholder that looks like a valid ISO code — instead of crashing. Downstream tax and compliance logic that depends on the country code will then silently operate on incorrect data.

---

```elixir
defmodule Payments.PhoneNormalizer do
  @moduledoc """
  Normalises customer phone numbers ingested from various payment gateway
  callbacks into a canonical E.164 representation, and extracts the country
  code for tax and compliance routing.
  """

  require Logger

  @e164_regex ~r/^\+?(\d{1,3})([\s\-\.]?\(?\d+\)?[\s\-\.]?){1,5}\d+$/
  @known_calling_codes %{
    "1"   => "US",
    "44"  => "GB",
    "49"  => "DE",
    "33"  => "FR",
    "55"  => "BR",
    "61"  => "AU",
    "81"  => "JP",
    "86"  => "CN",
    "91"  => "IN",
    "52"  => "MX"
  }

  @doc """
  Normalises the given phone number string and returns a map with the
  canonical number and the detected country code.
  """
  def normalise(phone) when is_binary(phone) do
    digits = strip_formatting(phone)

    %{
      e164:         build_e164(digits),
      country_code: extract_country_code(digits)
    }
  end

  @doc """
  Attempts to extract a two-letter ISO country code from a digit string
  by matching known calling-code prefixes.
  """

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because `extract_country_code/1` speculatively
  # falls back to `"XX"` whenever it cannot match a calling-code prefix.
  # The string `"XX"` is not a real ISO 3166-1 alpha-2 country code; it is an
  # invented placeholder that looks syntactically valid to downstream code.
  # Rather than crashing when the input does not match any known prefix, the
  # function silently returns a fake value, allowing tax-rate lookups,
  # compliance checks, and reporting to proceed with incorrect country data
  # and giving a false impression that the number was correctly identified.
  def extract_country_code(digits) when is_binary(digits) do
    Enum.find_value(@known_calling_codes, "XX", fn {prefix, country} ->
      if String.starts_with?(digits, prefix), do: country
    end)
  end

  def extract_country_code(_), do: "XX"
  # VALIDATION: SMELL END

  @doc """
  Strips all non-digit characters except a leading `+` from a phone string.
  """
  def strip_formatting(phone) when is_binary(phone) do
    phone
    |> String.trim()
    |> String.replace(~r/[^\d+]/, "")
    |> String.trim_leading("+")
  end

  defp build_e164(digits) when is_binary(digits) do
    if Regex.match?(@e164_regex, "+" <> digits) do
      "+" <> digits
    else
      raise ArgumentError, "cannot build E.164 from digits: #{inspect(digits)}"
    end
  end

  @doc """
  Returns true if the normalised E.164 number passes basic structural checks.
  """
  def valid_e164?(number) when is_binary(number) do
    Regex.match?(@e164_regex, number)
  end

  def valid_e164?(_), do: false

  @doc """
  Returns the full map of supported calling codes and their country codes.
  """
  def supported_calling_codes, do: @known_calling_codes
end
```
