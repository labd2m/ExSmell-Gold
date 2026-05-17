# Annotated Example — Speculative Assumptions

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `Payments.CardIdentifier.identify/1`, around the string slicing for BIN extraction
- **Affected function(s):** `identify/1`
- **Short explanation:** The function uses `String.slice/2` with hardcoded ranges to extract the BIN (Bank Identification Number) from a card number string after stripping spaces. If the card number is shorter than expected (truncated input, test cards, or non-standard formats), `String.slice/2` silently returns a shorter string or an empty string instead of crashing. The function then matches this partial BIN against ranges and may return a wrong or default card type, causing incorrect routing for payment processing.

---

```elixir
defmodule Payments.CardIdentifier do
  @moduledoc """
  Identifies the card network and card type from a raw PAN (Primary Account Number).
  Used during checkout to display the correct card logo and route to the appropriate
  payment processor.

  Supports: Visa, Mastercard, American Express, Discover, Elo, Hipercard.
  """

  require Logger

  @amex_prefixes   ["34", "37"]
  @discover_prefix  "6011"
  @elo_prefixes    ["4011", "4312", "4389", "6363", "6516", "6550"]
  @hipercard_prefix "6062"

  defstruct [:network, :type, :bin, :last_four, :length, :luhn_valid]

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because the function strips spaces and then uses
  # VALIDATION: String.slice/3 with hardcoded character ranges to extract the BIN
  # VALIDATION: prefix (first 6 digits) and last 4 digits. String.slice/3 never
  # VALIDATION: raises — if the string is shorter than the requested range, it silently
  # VALIDATION: returns whatever portion is available (possibly an empty string or a
  # VALIDATION: shorter prefix). A 10-digit test card number or a truncated PAN will
  # VALIDATION: produce a BIN of only 4 characters, which then matches no known prefix
  # VALIDATION: and defaults to :unknown — silently. The caller proceeds with an
  # VALIDATION: "unknown" card type instead of receiving an error, potentially routing
  # VALIDATION: the payment to a wrong processor or skipping fraud checks entirely.
  def identify(raw_pan) when is_binary(raw_pan) do
    pan = raw_pan |> String.replace(" ", "") |> String.replace("-", "")

    bin       = String.slice(pan, 0, 6)
    last_four = String.slice(pan, -4, 4)
    length    = String.length(pan)

    network = detect_network(bin)
    type    = detect_type(network, length)

    %__MODULE__{
      network:    network,
      type:       type,
      bin:        bin,
      last_four:  last_four,
      length:     length,
      luhn_valid: luhn_valid?(pan)
    }
  end
  # VALIDATION: SMELL END

  def identify(_), do: {:error, :invalid_pan}

  defp detect_network(bin) do
    cond do
      String.starts_with?(bin, "4") and bin in @elo_prefixes ->
        :elo

      String.starts_with?(bin, @amex_prefixes) ->
        :amex

      String.starts_with?(bin, "4") ->
        :visa

      String.starts_with?(bin, ["51", "52", "53", "54", "55"]) ->
        :mastercard

      String.starts_with?(bin, @discover_prefix) ->
        :discover

      String.starts_with?(bin, @hipercard_prefix) ->
        :hipercard

      true ->
        :unknown
    end
  end

  defp detect_type(:amex, 15),          do: :credit
  defp detect_type(:visa, 16),          do: :credit
  defp detect_type(:visa, 13),          do: :credit
  defp detect_type(:mastercard, 16),    do: :credit
  defp detect_type(:discover, 16),      do: :credit
  defp detect_type(:elo, 16),           do: :credit
  defp detect_type(:hipercard, 16),     do: :credit
  defp detect_type(_, _),               do: :unknown

  defp luhn_valid?(pan) do
    digits =
      pan
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)
      |> Enum.reverse()

    sum =
      digits
      |> Enum.with_index()
      |> Enum.reduce(0, fn {digit, i}, acc ->
        if rem(i, 2) == 1 do
          doubled = digit * 2
          acc + if doubled > 9, do: doubled - 9, else: doubled
        else
          acc + digit
        end
      end)

    rem(sum, 10) == 0
  rescue
    _ -> false
  end

  def masked(%__MODULE__{bin: bin, last_four: last4}) do
    "#{bin}******#{last4}"
  end

  def requires_cvv2?(%__MODULE__{network: :amex}), do: true
  def requires_cvv2?(_), do: false

  def processor_for(%__MODULE__{network: :visa}),       do: :stripe
  def processor_for(%__MODULE__{network: :mastercard}), do: :stripe
  def processor_for(%__MODULE__{network: :amex}),       do: :braintree
  def processor_for(%__MODULE__{network: :elo}),        do: :cielo
  def processor_for(%__MODULE__{network: :hipercard}),  do: :cielo
  def processor_for(_),                                 do: :default
end
```
