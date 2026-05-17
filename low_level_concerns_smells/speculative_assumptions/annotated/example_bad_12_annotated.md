# Annotated Example 12

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `Inventory.BinLocationParser.decode/1`
- **Affected function(s):** `decode/1`
- **Short explanation:** The function splits a warehouse bin location code on `"-"` and reads
  each logical component (warehouse, zone, aisle, rack, bin) at fixed indices via `Enum.at/2`.
  Some warehouse identifiers include a hyphenated site suffix (e.g. `"SYD-EAST"` instead of
  `"SYD"`). When such a code appears, every subsequent index is off by one and the function
  returns a plausible-looking struct whose `zone`, `aisle`, `rack`, and `bin` fields all hold
  wrong values, instead of crashing and signalling the unexpected format.

---

```elixir
defmodule Inventory.BinLocationParser do
  @moduledoc """
  Decodes structured bin location codes used in warehouse management operations.

  Bin location codes uniquely identify a physical storage position within a
  fulfilment centre. The canonical format is:

    "<WAREHOUSE>-<ZONE>-<AISLE>-<RACK>-<BIN>"

  Where:
    WAREHOUSE  — 2–6 uppercase letters  (e.g. "SYD", "MEL", "BNE")
    ZONE       — single uppercase letter (e.g. "A", "B", "C")
    AISLE      — two-digit zero-padded number (e.g. "03", "12")
    RACK       — two-digit zero-padded number (e.g. "04", "22")
    BIN        — alphanumeric shelf position  (e.g. "T1", "M3", "B6")

  Example codes:
    "SYD-A-03-04-T1"
    "MEL-C-12-22-B6"
    "BNE-B-07-11-M3"
  """

  defstruct [:warehouse, :zone, :aisle, :rack, :bin, :raw]

  @zone_labels ~w(A B C D E F G H)
  @aisle_range 1..30
  @rack_range  1..50

  @doc """
  Decodes a bin location code string into a `%BinLocationParser{}` struct.

  Returns `{:ok, struct}` on success or `{:error, reason}` if individual
  field validation fails after extraction.
  """

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because `decode/1` splits on "-" and uses `Enum.at/2`
  # VALIDATION: at fixed positions (0–4) to extract each component. Warehouses with
  # VALIDATION: hyphenated identifiers (e.g. "SYD-EAST-A-03-04-T1") produce an extra
  # VALIDATION: segment, shifting all subsequent indices by one. The function silently
  # VALIDATION: assigns "EAST" to zone, "A" to aisle, "03" to rack, and "04" to bin —
  # VALIDATION: all wrong — and then passes these values into structural validation which
  # VALIDATION: may still accept them, returning {:ok, struct} with entirely incorrect data.
  def decode(code) when is_binary(code) do
    parts = String.split(code, "-")

    warehouse = Enum.at(parts, 0)
    zone      = Enum.at(parts, 1)
    aisle     = Enum.at(parts, 2)
    rack      = Enum.at(parts, 3)
    bin       = Enum.at(parts, 4)

    with :ok <- validate_zone(zone),
         :ok <- validate_aisle(aisle),
         :ok <- validate_rack(rack) do
      {:ok, %__MODULE__{
        warehouse: warehouse,
        zone:      zone,
        aisle:     parse_int(aisle),
        rack:      parse_int(rack),
        bin:       bin,
        raw:       code
      }}
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Decodes a list of bin location codes, returning separate ok/error lists.
  """
  def decode_many(codes) when is_list(codes) do
    Enum.reduce(codes, %{ok: [], error: []}, fn code, acc ->
      case decode(code) do
        {:ok, loc}       -> %{acc | ok:    [loc | acc.ok]}
        {:error, reason} -> %{acc | error: [{code, reason} | acc.error]}
      end
    end)
    |> then(&%{&1 | ok: Enum.reverse(&1.ok), error: Enum.reverse(&1.error)})
  end

  @doc """
  Serialises a `%BinLocationParser{}` struct back into its canonical code string.
  """
  def encode(%__MODULE__{warehouse: w, zone: z, aisle: a, rack: r, bin: b}) do
    aisle_str = String.pad_leading(Integer.to_string(a), 2, "0")
    rack_str  = String.pad_leading(Integer.to_string(r), 2, "0")
    "#{w}-#{z}-#{aisle_str}-#{rack_str}-#{b}"
  end

  @doc """
  Returns a human-readable label for a decoded bin location.
  """
  def label(%__MODULE__{} = loc) do
    "#{loc.warehouse} / Zone #{loc.zone} / Aisle #{loc.aisle} / Rack #{loc.rack} / Bin #{loc.bin}"
  end

  @doc """
  Returns true if two locations are in the same aisle (used for pick-path optimisation).
  """
  def same_aisle?(%__MODULE__{warehouse: w, zone: z, aisle: a},
                  %__MODULE__{warehouse: w, zone: z, aisle: a}), do: true
  def same_aisle?(_, _), do: false

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_zone(zone) when is_binary(zone) do
    if String.upcase(zone) in @zone_labels do
      :ok
    else
      {:error, {:invalid_zone, zone}}
    end
  end

  defp validate_zone(nil), do: {:error, :missing_zone}
  defp validate_zone(_),   do: {:error, :invalid_zone}

  defp validate_aisle(aisle) when is_binary(aisle) do
    case Integer.parse(aisle) do
      {n, ""} when n in @aisle_range -> :ok
      {n, ""}                        -> {:error, {:aisle_out_of_range, n}}
      _                              -> {:error, {:invalid_aisle, aisle}}
    end
  end

  defp validate_aisle(nil), do: {:error, :missing_aisle}
  defp validate_aisle(_),   do: {:error, :invalid_aisle}

  defp validate_rack(rack) when is_binary(rack) do
    case Integer.parse(rack) do
      {n, ""} when n in @rack_range -> :ok
      {n, ""}                       -> {:error, {:rack_out_of_range, n}}
      _                             -> {:error, {:invalid_rack, rack}}
    end
  end

  defp validate_rack(nil), do: {:error, :missing_rack}
  defp validate_rack(_),   do: {:error, :invalid_rack}

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      _      -> nil
    end
  end
end
```
