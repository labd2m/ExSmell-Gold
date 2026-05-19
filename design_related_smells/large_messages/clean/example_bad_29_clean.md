```elixir
defmodule Ecommerce.ProductVariant do
  defstruct [:sku, :attributes, :price, :stock, :images]

  @type t :: %__MODULE__{
          sku: String.t(),
          attributes: %{String.t() => String.t()},
          price: float(),
          stock: non_neg_integer(),
          images: [String.t()]
        }
end

defmodule Ecommerce.Review do
  defstruct [:reviewer_id, :rating, :title, :body, :submitted_at, :helpful_votes]

  @type t :: %__MODULE__{
          reviewer_id: String.t(),
          rating: 1..5,
          title: String.t(),
          body: String.t(),
          submitted_at: DateTime.t(),
          helpful_votes: non_neg_integer()
        }
end

defmodule Ecommerce.Product do
  @enforce_keys [:id, :slug, :title, :category_path, :variants, :attributes]
  defstruct [
    :id,
    :slug,
    :title,
    :category_path,
    :description,
    :brand,
    :variants,
    :attributes,
    :tags,
    :reviews,
    :seo_metadata,
    :related_ids,
    :published_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          slug: String.t(),
          title: String.t(),
          category_path: [String.t()],
          description: String.t(),
          brand: String.t(),
          variants: [Ecommerce.ProductVariant.t()],
          attributes: map(),
          tags: [String.t()],
          reviews: [Ecommerce.Review.t()],
          seo_metadata: map(),
          related_ids: [String.t()],
          published_at: DateTime.t()
        }
end

defmodule Ecommerce.ProductCatalogue do
  @moduledoc "Returns the full active product catalogue."

  @spec load_all :: [Ecommerce.Product.t()]
  def load_all do
    now = DateTime.utc_now()

    Enum.map(1..25_000, fn n ->
      %Ecommerce.Product{
        id: "prod_#{n}",
        slug: "product-#{n}-#{rem(n * 7, 999_999)}",
        title: "Product #{n} – Premium Edition",
        brand: "Brand #{rem(n, 200) + 1}",
        category_path: [
          "Category #{rem(n, 20) + 1}",
          "Sub #{rem(n, 100) + 1}",
          "Leaf #{rem(n, 500) + 1}"
        ],
        description:
          "Detailed description for product #{n}. " <>
            String.duplicate("This product features high-quality materials and craftsmanship. ", 15),
        tags:
          Enum.map(1..8, fn t ->
            Enum.random(["sale", "new", "eco", "premium", "bundle", "clearance", "limited", "gift"]) <>
              "_#{t}"
          end),
        published_at: DateTime.add(now, -:rand.uniform(365) * 86_400, :second),
        seo_metadata: %{
          meta_title: "Buy Product #{n} Online | Shop",
          meta_description: "Best deals on Product #{n}. Free shipping on orders over $50.",
          canonical_url: "https://shop.example.com/products/product-#{n}",
          structured_data: %{type: "Product", sku: "SKU-#{n}", brand: "Brand #{rem(n, 200) + 1}"}
        },
        related_ids: Enum.map(1..6, fn r -> "prod_#{rem(n * r, 25_000) + 1}" end),
        attributes: %{
          colour: Enum.random(["red", "blue", "black", "white", "green"]),
          material: Enum.random(["cotton", "polyester", "leather", "metal"]),
          weight_g: :rand.uniform(5000),
          warranty_months: Enum.random([3, 6, 12, 24]),
          country_of_origin: Enum.random(["CN", "DE", "US", "BR"])
        },
        variants:
          Enum.map(1..8, fn v ->
            %Ecommerce.ProductVariant{
              sku: "SKU-#{n}-V#{v}",
              attributes: %{
                "size" => Enum.random(["XS", "S", "M", "L", "XL"]),
                "colour" => Enum.random(["red", "blue", "black"])
              },
              price: Float.round(10.0 + :rand.uniform() * 490, 2),
              stock: :rand.uniform(500),
              images:
                Enum.map(1..4, fn i ->
                  "https://cdn.example.com/products/#{n}/v#{v}/img#{i}.webp"
                end)
            }
          end),
        reviews:
          Enum.map(1..10, fn r ->
            %Ecommerce.Review{
              reviewer_id: "usr_#{rem(n * r, 200_000)}",
              rating: Enum.random(1..5),
              title: "Review #{r} for product #{n}",
              body: String.duplicate("Great product! Would recommend to anyone. ", 8),
              submitted_at: DateTime.add(now, -:rand.uniform(180) * 86_400, :second),
              helpful_votes: :rand.uniform(50)
            }
          end)
      }
    end)
  end
end

defmodule Ecommerce.SearchIndexerWorker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, [], opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:index_products, products}, _state) do
    {:noreply, products}
  end
end

defmodule Ecommerce.CatalogPublisher do
  @moduledoc """
  Loads the full product catalogue and sends it to the search indexer
  process so that the search index can be rebuilt from scratch.
  """

  require Logger

  @spec publish_to_search_indexer(pid()) :: :ok
  def publish_to_search_indexer(indexer_pid) do
    Logger.info("Loading full product catalogue for search index rebuild...")

    products = Ecommerce.ProductCatalogue.load_all()

    Logger.info("Loaded #{length(products)} products. Sending to search indexer...")

    send(indexer_pid, {:index_products, products})

    Logger.info("Catalogue dispatched to search indexer.")
    :ok
  end
end
```
