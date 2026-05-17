```elixir
defmodule Inventory.SkuVariantParser do
  @moduledoc """
  Decodes product SKU variant codes used in the inventory and order management systems.

  SKU variant codes encode the key product dimensions that distinguish individual
  stock-keeping units within a product family:

    "<BASE_PRODUCT_CODE>-<COLOUR>-<SIZE>-<YEAR>"

  Examples:
    "POLO-WHITE-M-2024"
    "POLO-BLACK-XL-2024"
    "CHINO-KHAKI-32x30-2023"
    "HOODIE-GREY-L-2024"

  SKU codes are issued by the merchandising team and stored in the PIM.
  They are used for stock receipt scanning, order fulfilment, and reorder automation.
  """

  require Logger

  @known_sizes   ~w(XS S M L XL XXL XXXL 28x30 28x32 30x30 30x32 32x30 32x32 34x32 36x32)
  @current_years [2022, 2023, 2024, 2025]

  defstruct [:base_code, :colour, :size, :year, :raw]

  @doc """
  Decodes a SKU variant code string into a `%SkuVariantParser{}` struct.

  Returns `{:ok, struct}` when the size and year are recognised values.
  Returns `{:error, reason}` when size or year validation fails.
  """

  def decode(sku) when is_binary(sku) do
    parts     = String.split(sku, "-")
    base_code = Enum.at(parts, 0)
    colour    = Enum.at(parts, 1)
    size      = Enum.at(parts, 2)
    raw_year  = Enum.at(parts, 3)

    with :ok <- validate_size(size),
         {:ok, year} <- parse_year(raw_year) do
      {:ok, %__MODULE__{
        base_code: base_code,
        colour:    colour,
        size:      size,
        year:      year,
        raw:       sku
      }}
    end
  end

  @doc """
  Decodes a list of SKU codes and partitions results into successes and failures.
  """
  def decode_many(skus) when is_list(skus) do
    Enum.reduce(skus, %{ok: [], error: []}, fn sku, acc ->
      case decode(sku) do
        {:ok, variant}   -> %{acc | ok:    [variant | acc.ok]}
        {:error, reason} -> %{acc | error: [{sku, reason} | acc.error]}
      end
    end)
    |> then(&%{&1 | ok: Enum.reverse(&1.ok), error: Enum.reverse(&1.error)})
  end

  @doc """
  Groups a list of decoded SKU structs by their base product code.
  """
  def group_by_product(variants) when is_list(variants) do
    Enum.group_by(variants, & &1.base_code)
  end

  @doc """
  Returns all variants from a list that match a given colour token.
  """
  def by_colour(variants, colour) when is_list(variants) and is_binary(colour) do
    Enum.filter(variants, &(String.upcase(&1.colour || "") == String.upcase(colour)))
  end

  @doc """
  Returns all variants from a given model year.
  """
  def by_year(variants, year) when is_list(variants) and is_integer(year) do
    Enum.filter(variants, &(&1.year == year))
  end

  @doc """
  Returns the display label for a variant, suitable for use in order confirmation emails.
  """
  def display_label(%__MODULE__{base_code: code, colour: colour, size: size, year: year}) do
    "#{code} / #{String.capitalize(colour || "?")} / #{size} (#{year})"
  end

  @doc """
  Returns all valid size codes recognised by the platform.
  """
  def known_sizes, do: @known_sizes

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_size(size) when is_binary(size) do
    if size in @known_sizes do
      :ok
    else
      {:error, {:unknown_size, size}}
    end
  end

  defp validate_size(nil), do: {:error, :missing_size}
  defp validate_size(_),   do: {:error, :invalid_size}

  defp parse_year(nil), do: {:error, :missing_year}

  defp parse_year(str) when is_binary(str) do
    case Integer.parse(str) do
      {y, ""} when y in @current_years -> {:ok, y}
      {y, ""}                          -> {:error, {:year_out_of_range, y}}
      _                                -> {:error, {:invalid_year, str}}
    end
  end
end
```
