# Annotated Example 25

## Metadata

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `SkuGenerator.generate/2`
- **Affected function(s):** `generate/2`
- **Short explanation:** The library function `generate/2` reads `:sku_prefix` and `:sequence_padding` from the `Application` environment. This forces all dependent applications to use the same prefix and padding for every SKU, making it impossible for a multi-tenant inventory system to generate SKUs with distinct tenant-specific prefixes from the same library without altering global state.

---

```elixir
defmodule SkuGenerator do
  @moduledoc """
  Library for generating Stock Keeping Unit (SKU) codes for inventory items.
  Used in e-commerce platforms, warehouse management systems, and
  product catalog services.
  """

  @type product :: %{
          category_code: String.t(),
          variant_code: String.t(),
          sequence: non_neg_integer()
        }

  @type sku_result ::
          {:ok, String.t()}
          | {:error, :invalid_category}
          | {:error, :invalid_variant}
          | {:error, :invalid_sequence}

  @doc """
  Generates a SKU string from a product map.
  The SKU format is: <PREFIX>-<CATEGORY>-<VARIANT>-<PADDED_SEQUENCE>
  The prefix and sequence padding width are read from application config.
  """
  @spec generate(product()) :: sku_result()
  def generate(%{category_code: cat, variant_code: var, sequence: seq}) do
    with :ok <- validate_category(cat),
         :ok <- validate_variant(var),
         :ok <- validate_sequence(seq) do
      # VALIDATION: SMELL START - Using App Configuration for libraries
      # VALIDATION: This is a smell because generate/1 is a library function that
      # fetches :sku_prefix and :sequence_padding from the Application environment
      # rather than accepting them as parameters or options. A multi-tenant
      # application needing different SKU prefixes per tenant (e.g., "ACME-" vs
      # "GLOBX-") cannot do so without resetting the global Application environment
      # between calls, which is unsafe in a concurrent system.
      prefix = Application.fetch_env!(:sku_generator, :sku_prefix)
      padding = Application.fetch_env!(:sku_generator, :sequence_padding)
      # VALIDATION: SMELL END

      padded_seq = seq |> Integer.to_string() |> String.pad_leading(padding, "0")
      sku = Enum.join([prefix, String.upcase(cat), String.upcase(var), padded_seq], "-")
      {:ok, sku}
    end
  end

  @doc """
  Generates SKUs in bulk for a list of product maps.
  Returns a list of `{:ok, sku}` or `{:error, reason}` tuples.
  """
  @spec generate_batch([product()]) :: [sku_result()]
  def generate_batch(products) when is_list(products) do
    Enum.map(products, &generate/1)
  end

  @doc """
  Parses an existing SKU string and returns its constituent parts.
  Assumes the standard PREFIX-CATEGORY-VARIANT-SEQUENCE format.
  """
  @spec parse(String.t()) :: {:ok, map()} | {:error, :invalid_sku}
  def parse(sku) when is_binary(sku) do
    case String.split(sku, "-") do
      [prefix, category, variant, sequence] ->
        case Integer.parse(sequence) do
          {seq, ""} ->
            {:ok,
             %{
               prefix: prefix,
               category_code: String.downcase(category),
               variant_code: String.downcase(variant),
               sequence: seq
             }}

          _ ->
            {:error, :invalid_sku}
        end

      _ ->
        {:error, :invalid_sku}
    end
  end

  @doc "Returns true if the given string is a syntactically valid SKU."
  @spec valid_sku?(String.t()) :: boolean()
  def valid_sku?(sku) when is_binary(sku) do
    match?({:ok, _}, parse(sku))
  end

  @doc "Increments the sequence component of a SKU by one."
  @spec increment(String.t()) :: {:ok, String.t()} | {:error, :invalid_sku}
  def increment(sku) do
    with {:ok, parts} <- parse(sku) do
      generate(%{
        category_code: parts.category_code,
        variant_code: parts.variant_code,
        sequence: parts.sequence + 1
      })
    end
  end

  # --- Private helpers ---

  defp validate_category(cat) when is_binary(cat) do
    if Regex.match?(~r/^[a-zA-Z]{2,6}$/, cat), do: :ok, else: {:error, :invalid_category}
  end

  defp validate_variant(var) when is_binary(var) do
    if Regex.match?(~r/^[a-zA-Z0-9]{1,8}$/, var), do: :ok, else: {:error, :invalid_variant}
  end

  defp validate_sequence(seq) when is_integer(seq) and seq >= 0, do: :ok
  defp validate_sequence(_), do: {:error, :invalid_sequence}
end
```
