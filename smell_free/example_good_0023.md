```elixir
defprotocol Catalog.Exportable do
  @moduledoc """
  Protocol for converting domain structs into portable, version-stamped maps
  suitable for JSON serialization and external system interchange.
  """

  @doc "Converts the struct to a plain export map."
  @spec to_export_map(t()) :: map()
  def to_export_map(struct)

  @doc "Returns the schema version string for this struct's serialization format."
  @spec schema_version(t()) :: String.t()
  def schema_version(struct)
end

defmodule Catalog.Product do
  @moduledoc "Domain struct representing a catalog product."

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          sku: String.t(),
          name: String.t(),
          price_cents: non_neg_integer(),
          currency: String.t(),
          tags: [String.t()],
          active: boolean()
        }

  defstruct [:id, :sku, :name, :price_cents, currency: "USD", tags: [], active: true]
end

defimpl Catalog.Exportable, for: Catalog.Product do
  @moduledoc false

  @schema_version "product.v2"

  def to_export_map(%Catalog.Product{} = product) do
    %{
      id: product.id,
      sku: product.sku,
      name: product.name,
      price: price_map(product.price_cents, product.currency),
      tags: product.tags,
      active: product.active
    }
  end

  def schema_version(_product), do: @schema_version

  defp price_map(cents, currency) when is_integer(cents) and is_binary(currency) do
    %{amount_cents: cents, currency: currency}
  end
end

defmodule Catalog.Category do
  @moduledoc "Domain struct representing a product category."

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          slug: String.t(),
          name: String.t(),
          parent_id: pos_integer() | nil
        }

  defstruct [:id, :slug, :name, :parent_id]
end

defimpl Catalog.Exportable, for: Catalog.Category do
  @moduledoc false

  @schema_version "category.v1"

  def to_export_map(%Catalog.Category{} = category) do
    %{
      id: category.id,
      slug: category.slug,
      name: category.name,
      parent_id: category.parent_id
    }
  end

  def schema_version(_category), do: @schema_version
end

defmodule Catalog.BulkExporter do
  @moduledoc """
  Serializes a homogeneous list of `Catalog.Exportable` structs into a
  versioned export envelope ready for downstream consumers.
  """

  alias Catalog.Exportable

  @type export_envelope :: %{
          schema_version: String.t(),
          exported_at: String.t(),
          record_count: non_neg_integer(),
          records: [map()]
        }

  @doc """
  Builds a versioned export envelope from a non-empty list of exportable structs.
  All items must be the same type and implement `Catalog.Exportable`.
  """
  @spec build([Exportable.t()]) :: {:ok, export_envelope()} | {:error, :empty_list}
  def build([_ | _] = items) do
    [first | _] = items

    envelope = %{
      schema_version: Exportable.schema_version(first),
      exported_at: DateTime.to_iso8601(DateTime.utc_now()),
      record_count: length(items),
      records: Enum.map(items, &Exportable.to_export_map/1)
    }

    {:ok, envelope}
  end

  def build([]), do: {:error, :empty_list}
end
```
