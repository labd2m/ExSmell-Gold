```elixir
defmodule Catalog.Product do
  @moduledoc """
  Domain struct representing a sellable product within the product catalog.
  Provides changesets for creation, pricing updates, and availability toggling.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
    id: Ecto.UUID.t(),
    sku: String.t(),
    name: String.t(),
    description: String.t(),
    price_cents: pos_integer(),
    currency: String.t(),
    available: boolean(),
    inserted_at: DateTime.t(),
    updated_at: DateTime.t()
  }

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "products" do
    field :sku, :string
    field :name, :string
    field :description, :string
    field :price_cents, :integer
    field :currency, :string, default: "USD"
    field :available, :boolean, default: true

    timestamps()
  end

  @spec creation_changeset(map()) :: Ecto.Changeset.t()
  def creation_changeset(params) do
    %__MODULE__{}
    |> cast(params, [:sku, :name, :description, :price_cents, :currency])
    |> validate_required([:sku, :name, :price_cents])
    |> validate_length(:sku, min: 3, max: 50)
    |> validate_length(:name, min: 2, max: 200)
    |> validate_number(:price_cents, greater_than: 0)
    |> validate_inclusion(:currency, ["USD", "EUR", "GBP", "BRL"])
    |> unique_constraint(:sku)
  end

  @spec pricing_changeset(t(), map()) :: Ecto.Changeset.t()
  def pricing_changeset(%__MODULE__{} = product, params) do
    product
    |> cast(params, [:price_cents, :currency])
    |> validate_required([:price_cents, :currency])
    |> validate_number(:price_cents, greater_than: 0)
    |> validate_inclusion(:currency, ["USD", "EUR", "GBP", "BRL"])
  end

  @spec availability_changeset(t(), boolean()) :: Ecto.Changeset.t()
  def availability_changeset(%__MODULE__{} = product, available) when is_boolean(available) do
    product
    |> cast(%{available: available}, [:available])
    |> validate_required([:available])
  end
end

defmodule Catalog.ProductContext do
  @moduledoc """
  Application-layer operations for product catalog management.
  Enforces business invariants and coordinates persistence.
  """

  import Ecto.Query, only: [from: 2]

  alias Catalog.{Product, Repo}

  @spec create_product(map()) :: {:ok, Product.t()} | {:error, Ecto.Changeset.t()}
  def create_product(params) when is_map(params) do
    params
    |> Product.creation_changeset()
    |> Repo.insert()
  end

  @spec update_price(Product.t(), pos_integer(), String.t()) ::
          {:ok, Product.t()} | {:error, Ecto.Changeset.t()}
  def update_price(%Product{} = product, new_price, currency)
      when is_integer(new_price) and is_binary(currency) do
    product
    |> Product.pricing_changeset(%{price_cents: new_price, currency: currency})
    |> Repo.update()
  end

  @spec set_availability(Product.t(), boolean()) ::
          {:ok, Product.t()} | {:error, Ecto.Changeset.t()}
  def set_availability(%Product{} = product, available) do
    product
    |> Product.availability_changeset(available)
    |> Repo.update()
  end

  @spec list_available(keyword()) :: [Product.t()]
  def list_available(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(p in Product,
      where: p.available == true,
      order_by: [asc: p.name],
      limit: ^limit
    )
    |> Repo.all()
  end

  @spec find_by_sku(String.t()) :: {:ok, Product.t()} | {:error, :not_found}
  def find_by_sku(sku) when is_binary(sku) do
    case Repo.get_by(Product, sku: sku) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end
end
```
