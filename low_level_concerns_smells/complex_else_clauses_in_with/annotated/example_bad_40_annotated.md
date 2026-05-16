# Annotated Example 40 — Complex else clauses in with

## Metadata

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `import_product/2`, inside the `with` expression's `else` block
- **Affected function(s):** `import_product/2`
- **Short explanation:** Five import steps each emit a differently shaped failure. The undifferentiated `else` block collapses them all, making it unclear which step produced a given error without re-reading the entire `with` expression.

---

```elixir
defmodule Catalog.ProductImporter do
  @moduledoc """
  Imports products from a supplier feed into the internal catalog:
  parsing, category resolution, duplicate detection, enrichment, and persistence.
  """

  alias Catalog.{
    FeedParser,
    CategoryResolver,
    DuplicateDetector,
    ProductEnricher,
    ProductRepo
  }

  require Logger

  @doc """
  Imports a single raw product `entry` submitted by `supplier_id`.

  Returns `{:ok, product}` or a structured import error.
  """
  @spec import_product(String.t(), map()) ::
          {:ok, map()}
          | {:error, :parse_failed, String.t()}
          | {:error, :unknown_category}
          | {:error, :duplicate, String.t()}
          | {:error, :enrichment_failed}
          | {:error, :persistence_failed}
  def import_product(supplier_id, raw_entry) do
    # VALIDATION: SMELL START - Complex else clauses in with
    # VALIDATION: This is a smell because five with-clauses each fail with a
    # distinct structure ({:error, :parse, _}, {:error, :unknown_category},
    # {:duplicate, _}, {:error, :enrich}, {:error, changeset}).
    # The flat else block aggregates all patterns without structural indication
    # of which pipeline step produced each one.
    with {:ok, parsed}   <- FeedParser.parse(raw_entry, supplier_id),
         {:ok, category} <- CategoryResolver.resolve(parsed.category_code),
         :ok             <- DuplicateDetector.check(supplier_id, parsed.sku),
         {:ok, enriched} <- ProductEnricher.enrich(parsed, category),
         {:ok, product}  <- ProductRepo.upsert(%{
                              supplier_id:  supplier_id,
                              sku:          parsed.sku,
                              name:         enriched.name,
                              description:  enriched.description,
                              category_id:  category.id,
                              attributes:   enriched.attributes,
                              price_cents:  parsed.price_cents,
                              currency:     parsed.currency,
                              imported_at:  DateTime.utc_now()
                            }) do
      Logger.info("Imported product #{product.id} (SKU: #{parsed.sku}) from supplier #{supplier_id}")
      {:ok, product}
    else
      {:error, :parse, reason} ->
        Logger.warn("Feed parse error for supplier #{supplier_id}: #{reason}")
        {:error, :parse_failed, reason}

      {:error, :unknown_category} ->
        Logger.warn("Unknown category code in entry from #{supplier_id}")
        {:error, :unknown_category}

      {:duplicate, existing_id} ->
        Logger.info("Duplicate SKU detected, existing product: #{existing_id}")
        {:error, :duplicate, existing_id}

      {:error, :enrich} ->
        Logger.error("Product enrichment failed for SKU from #{supplier_id}")
        {:error, :enrichment_failed}

      {:error, %Ecto.Changeset{} = cs} ->
        Logger.error("Product persistence failed: #{inspect(cs.errors)}")
        {:error, :persistence_failed}
    end
    # VALIDATION: SMELL END
  end
end
```
