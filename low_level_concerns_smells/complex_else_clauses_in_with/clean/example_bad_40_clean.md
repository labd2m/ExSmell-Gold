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
  end
end
```
