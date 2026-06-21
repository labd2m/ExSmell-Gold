```elixir
defmodule Catalog.Product do
  @moduledoc """
  Ecto schema and changeset functions for catalog products.

  Changesets are the sole authorised path for creating or modifying a product,
  enforcing all domain constraints (SKU format, price bounds, status transitions)
  before any persistence call is made.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type status :: :draft | :active | :discontinued
  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          sku: String.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          price_cents: non_neg_integer() | nil,
          currency: String.t(),
          stock_quantity: non_neg_integer(),
          status: status(),
          tags: [String.t()],
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @valid_statuses [:draft, :active, :discontinued]
  @valid_currencies ~w[USD EUR GBP BRL JPY CAD AUD]
  @sku_format ~r/^[A-Z0-9\-]{4,20}$/

  schema "products" do
    field :sku, :string
    field :name, :string
    field :description, :string
    field :price_cents, :integer
    field :currency, :string, default: "USD"
    field :stock_quantity, :integer, default: 0
    field :status, Ecto.Enum, values: @valid_statuses, default: :draft
    field :tags, {:array, :string}, default: []
    timestamps()
  end

  @doc """
  Validates and casts attributes for creating a new product.
  """
  @spec creation_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def creation_changeset(product \\ %__MODULE__{}, attrs) do
    product
    |> cast(attrs, [:sku, :name, :description, :price_cents, :currency, :stock_quantity, :status, :tags])
    |> validate_required([:sku, :name, :price_cents, :currency])
    |> validate_sku_format()
    |> validate_price()
    |> validate_stock()
    |> validate_inclusion(:currency, @valid_currencies)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:sku)
  end

  @doc """
  Validates and casts attributes for updating an existing product.
  SKU is immutable after creation.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = product, attrs) do
    product
    |> cast(attrs, [:name, :description, :price_cents, :stock_quantity, :status, :tags])
    |> validate_required([:name, :price_cents])
    |> validate_price()
    |> validate_stock()
    |> validate_inclusion(:status, @valid_statuses)
  end

  @doc """
  Produces a changeset that transitions a `:draft` product to `:active`.
  Returns an invalid changeset for products not in `:draft` status.
  """
  @spec activate_changeset(t()) :: Ecto.Changeset.t()
  def activate_changeset(%__MODULE__{status: :draft} = product) do
    change(product, %{status: :active})
  end

  def activate_changeset(%__MODULE__{} = product) do
    product
    |> change()
    |> add_error(:status, "can only be activated from draft")
  end

  @doc """
  Produces a changeset that transitions an `:active` product to `:discontinued`.
  """
  @spec discontinue_changeset(t()) :: Ecto.Changeset.t()
  def discontinue_changeset(%__MODULE__{status: :active} = product) do
    change(product, %{status: :discontinued})
  end

  def discontinue_changeset(%__MODULE__{} = product) do
    product
    |> change()
    |> add_error(:status, "can only discontinue an active product")
  end

  defp validate_sku_format(changeset) do
    changeset
    |> validate_length(:sku, min: 4, max: 20)
    |> validate_format(:sku, @sku_format,
      message: "must be uppercase letters, digits, and hyphens only"
    )
  end

  defp validate_price(changeset) do
    validate_number(changeset, :price_cents, greater_than_or_equal_to: 0)
  end

  defp validate_stock(changeset) do
    validate_number(changeset, :stock_quantity, greater_than_or_equal_to: 0)
  end
end
```
