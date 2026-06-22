**File:** `example_good_1068.md`

```elixir
defmodule Inventory.Product do
  @moduledoc """
  Ecto schema for inventory products with multi-step changeset validation.
  Domain invariants are enforced at the changeset level, keeping the
  database the source of truth for structural integrity.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Inventory.{Category, Supplier}

  @type status :: :draft | :active | :discontinued

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          sku: String.t(),
          name: String.t(),
          description: String.t() | nil,
          category_id: Ecto.UUID.t(),
          supplier_id: Ecto.UUID.t(),
          unit_price_cents: pos_integer(),
          currency: String.t(),
          stock_quantity: non_neg_integer(),
          reorder_threshold: non_neg_integer(),
          status: status(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "products" do
    field :sku, :string
    field :name, :string
    field :description, :string
    field :unit_price_cents, :integer
    field :currency, :string, default: "usd"
    field :stock_quantity, :integer, default: 0
    field :reorder_threshold, :integer, default: 0
    field :status, Ecto.Enum, values: [:draft, :active, :discontinued], default: :draft

    belongs_to :category, Category
    belongs_to :supplier, Supplier

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(sku name category_id supplier_id unit_price_cents currency)a
  @optional_fields ~w(description stock_quantity reorder_threshold status)a
  @supported_currencies ~w(usd eur gbp jpy cad aud)

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(product, attrs) do
    product
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_sku_format()
    |> validate_pricing()
    |> validate_currency()
    |> validate_stock_config()
    |> unique_constraint(:sku)
    |> foreign_key_constraint(:category_id)
    |> foreign_key_constraint(:supplier_id)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(product, attrs) do
    product
    |> cast(attrs, @optional_fields ++ [:name, :description, :unit_price_cents])
    |> validate_pricing()
    |> validate_stock_config()
  end

  @spec activate_changeset(t()) :: Ecto.Changeset.t()
  def activate_changeset(%__MODULE__{status: :draft} = product) do
    product
    |> change(status: :active)
    |> validate_required([:description])
  end

  def activate_changeset(%__MODULE__{status: status} = product) do
    product
    |> change()
    |> add_error(:status, "cannot activate product with status #{status}")
  end

  @spec discontinue_changeset(t()) :: Ecto.Changeset.t()
  def discontinue_changeset(%__MODULE__{} = product) do
    change(product, status: :discontinued)
  end

  defp validate_sku_format(changeset) do
    validate_format(changeset, :sku, ~r/\A[A-Z0-9\-]{3,20}\z/,
      message: "must be 3-20 uppercase letters, digits, or dashes"
    )
  end

  defp validate_pricing(changeset) do
    changeset
    |> validate_number(:unit_price_cents, greater_than: 0, message: "must be a positive amount")
  end

  defp validate_currency(changeset) do
    validate_inclusion(changeset, :currency, @supported_currencies,
      message: "must be one of #{Enum.join(@supported_currencies, ", ")}"
    )
  end

  defp validate_stock_config(changeset) do
    changeset
    |> validate_number(:stock_quantity, greater_than_or_equal_to: 0)
    |> validate_number(:reorder_threshold, greater_than_or_equal_to: 0)
  end
end
```
