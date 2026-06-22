**File:** `example_good_1381.md`

```elixir
defmodule Mix.Tasks.Catalog.SyncProducts do
  @moduledoc """
  Fetches product data from the upstream catalog API and upserts
  records into the local database. Runs as an idempotent Mix task.

  Usage:
      mix catalog.sync_products [--dry-run] [--limit N]
  """

  use Mix.Task

  alias Catalog.{Products, ExternalClient}

  @shortdoc "Syncs products from the upstream catalog API"

  @switches [dry_run: :boolean, limit: :integer]
  @defaults [dry_run: false, limit: 500]

  @impl Mix.Task
  def run(argv) do
    Application.ensure_all_started(:catalog)

    {opts, _} = OptionParser.parse!(argv, strict: @switches)
    config = Keyword.merge(@defaults, opts)

    Mix.shell().info("Starting product sync (dry_run=#{config[:dry_run]}, limit=#{config[:limit]})")

    case ExternalClient.fetch_products(config[:limit]) do
      {:ok, products} ->
        sync_products(products, config[:dry_run])

      {:error, reason} ->
        Mix.shell().error("Failed to fetch products from upstream: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp sync_products(products, true) do
    Mix.shell().info("Dry run: would upsert #{length(products)} product(s). No changes written.")
  end

  defp sync_products(products, false) do
    {inserted, updated, failed} = perform_upserts(products)

    Mix.shell().info("Sync complete: #{inserted} inserted, #{updated} updated, #{failed} failed.")
  end

  defp perform_upserts(products) do
    Enum.reduce(products, {0, 0, 0}, fn product, {ins, upd, fail} ->
      case Products.upsert(product) do
        {:ok, :inserted} -> {ins + 1, upd, fail}
        {:ok, :updated} -> {ins, upd + 1, fail}
        {:error, reason} ->
          Mix.shell().error("Failed to upsert product #{product.external_id}: #{inspect(reason)}")
          {ins, upd, fail + 1}
      end
    end)
  end
end

defmodule Catalog.Products do
  @moduledoc """
  Context for managing catalog product records.
  """

  import Ecto.Query, warn: false

  alias Catalog.Repo
  alias Catalog.Products.Product

  @type upsert_result :: {:ok, :inserted | :updated} | {:error, Ecto.Changeset.t()}

  @spec upsert(map()) :: upsert_result()
  def upsert(%{external_id: _} = attrs) do
    case Repo.get_by(Product, external_id: attrs.external_id) do
      nil -> insert_product(attrs)
      existing -> update_product(existing, attrs)
    end
  end

  defp insert_product(attrs) do
    %Product{}
    |> Product.changeset(attrs)
    |> Repo.insert()
    |> wrap_result(:inserted)
  end

  defp update_product(existing, attrs) do
    existing
    |> Product.changeset(attrs)
    |> Repo.update()
    |> wrap_result(:updated)
  end

  defp wrap_result({:ok, _}, tag), do: {:ok, tag}
  defp wrap_result({:error, _} = err, _tag), do: err
end

defmodule Catalog.Products.Product do
  @moduledoc "Schema for a synchronized catalog product."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          external_id: String.t(),
          name: String.t(),
          sku: String.t(),
          price_cents: pos_integer(),
          active: boolean()
        }

  schema "products" do
    field :external_id, :string
    field :name, :string
    field :sku, :string
    field :price_cents, :integer
    field :active, :boolean, default: true
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(product, attrs) do
    product
    |> cast(attrs, [:external_id, :name, :sku, :price_cents, :active])
    |> validate_required([:external_id, :name, :sku, :price_cents])
    |> validate_number(:price_cents, greater_than: 0)
    |> validate_length(:sku, min: 1, max: 64)
    |> unique_constraint(:external_id)
    |> unique_constraint(:sku)
  end
end
```
