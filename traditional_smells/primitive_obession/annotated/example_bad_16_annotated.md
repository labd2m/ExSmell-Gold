# Annotated Example: Primitive Obsession

## Metadata

- **Smell Name**: Primitive Obsession
- **Expected Smell Location**: `register_variant/4`, `find_by_color/2`, `color_distance/2`, `blend_colors/3`
- **Affected Function(s)**: All public functions in `Inventory.ColorVariantManager`
- **Explanation**: A product colour is passed and stored as a raw `String.t()` hex value (e.g., `"#FF5733"`) rather than a `%Color{hex: String.t(), r: 0..255, g: 0..255, b: 0..255, label: String.t()}` struct. This spreads parsing, validation, and component-extraction logic across multiple private helpers and forces every caller to re-parse the hex string rather than accessing pre-parsed components.

## Code

```elixir
defmodule Inventory.ColorVariantManager do
  @moduledoc """
  Manages colour variants for product SKUs in the inventory system.
  Supports hex-based colour registration, nearest-colour search,
  colour blending for custom order production, and similarity scoring
  for recommendation matching.
  """

  require Logger

  @similarity_threshold 30

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because a product colour is represented as a
  # VALIDATION: raw `String.t()` hex code (e.g., "#A3C4BC") rather than a
  # VALIDATION: `%Color{hex: String.t(), r: integer(), g: integer(), b: integer(),
  # VALIDATION: label: String.t()}` struct. Component extraction via hex parsing
  # VALIDATION: is repeated across `blend_colors/3`, `color_distance/2`, and
  # VALIDATION: `find_by_color/2`, and any misspelled or unvalidated hex string
  # VALIDATION: propagates silently until it causes a runtime parse failure.
  @spec register_variant(String.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, String.t()}
  def register_variant(sku, color_hex, color_label, stock_quantity) do
    with :ok <- validate_hex_color(color_hex) do
      normalised_hex = normalise_hex(color_hex)

      variant = %{
        sku: sku,
        color_hex: normalised_hex,
        color_label: color_label,
        stock_quantity: stock_quantity,
        created_at: DateTime.utc_now()
      }

      Logger.info("Registered variant #{sku} with colour #{normalised_hex} (#{color_label})")
      {:ok, variant}
    end
  end

  @spec find_by_color(list(map()), String.t()) :: list(map())
  def find_by_color(variants, target_hex) do
    case validate_hex_color(target_hex) do
      {:error, reason} ->
        Logger.warning("Invalid target hex for search: #{reason}")
        []

      :ok ->
        normalised = normalise_hex(target_hex)

        Enum.filter(variants, fn variant ->
          distance = color_distance(variant.color_hex, normalised)
          distance <= @similarity_threshold
        end)
    end
  end

  @spec color_distance(String.t(), String.t()) :: float()
  def color_distance(hex_a, hex_b) do
    with {:ok, {ra, ga, ba}} <- parse_rgb(hex_a),
         {:ok, {rb, gb, bb}} <- parse_rgb(hex_b) do
      dr = ra - rb
      dg = ga - gb
      db = ba - bb
      :math.sqrt(dr * dr + dg * dg + db * db)
    else
      _ -> 999.0
    end
  end

  @spec blend_colors(String.t(), String.t(), float()) ::
          {:ok, String.t()} | {:error, String.t()}
  def blend_colors(hex_a, hex_b, weight_a \\ 0.5) do
    with :ok <- validate_hex_color(hex_a),
         :ok <- validate_hex_color(hex_b),
         {:ok, {ra, ga, ba}} <- parse_rgb(hex_a),
         {:ok, {rb, gb, bb}} <- parse_rgb(hex_b) do
      weight_b = 1.0 - weight_a

      r = round(ra * weight_a + rb * weight_b)
      g = round(ga * weight_a + gb * weight_b)
      b = round(ba * weight_a + bb * weight_b)

      blended =
        "##{Integer.to_string(r, 16) |> String.pad_leading(2, "0")}#{Integer.to_string(g, 16) |> String.pad_leading(2, "0")}#{Integer.to_string(b, 16) |> String.pad_leading(2, "0")}"
        |> String.upcase()

      {:ok, blended}
    end
  end

  @spec is_similar?(String.t(), String.t()) :: boolean()
  def is_similar?(hex_a, hex_b) do
    color_distance(hex_a, hex_b) <= @similarity_threshold
  end
  # VALIDATION: SMELL END

  defp validate_hex_color(hex) do
    normalised = String.trim(hex)

    if String.match?(normalised, ~r/^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$/) do
      :ok
    else
      {:error, "Invalid hex colour '#{hex}'. Expected format: #RGB or #RRGGBB"}
    end
  end

  defp normalise_hex("#" <> rest) when byte_size(rest) == 3 do
    [r, g, b] = String.graphemes(rest)
    "##{r}#{r}#{g}#{g}#{b}#{b}" |> String.upcase()
  end

  defp normalise_hex(hex), do: String.upcase(hex)

  defp parse_rgb("#" <> hex) when byte_size(hex) == 6 do
    r = String.slice(hex, 0, 2) |> String.to_integer(16)
    g = String.slice(hex, 2, 2) |> String.to_integer(16)
    b = String.slice(hex, 4, 2) |> String.to_integer(16)
    {:ok, {r, g, b}}
  rescue
    _ -> {:error, "Could not parse hex colour"}
  end

  defp parse_rgb(hex), do: parse_rgb(normalise_hex(hex))
end
```
