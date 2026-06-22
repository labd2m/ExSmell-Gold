```elixir
defmodule Catalog.Variant do
  @moduledoc """
  An Ecto schema representing a product variant with polymorphic attributes.
  Variants for clothing carry size and colour; variants for digital products
  carry download format and licence type. The `attributes` field holds a
  typed embedded schema selected at cast time via a discriminator field,
  keeping the variants table normalised while supporting heterogeneous shapes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "product_variants" do
    belongs_to :product, Catalog.Product
    field :sku, :string
    field :price_cents, :integer
    field :stock_quantity, :integer, default: 0
    field :variant_type, Ecto.Enum, values: [:physical, :digital, :subscription]
    embeds_one :attributes, Catalog.Variant.Attributes, on_replace: :delete
    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc """
  Builds and validates a variant changeset. The `:variant_type` field
  controls which attribute schema is cast for the embedded `attributes` map.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = variant, attrs) do
    variant
    |> cast(attrs, [:sku, :price_cents, :stock_quantity, :variant_type])
    |> validate_required([:sku, :price_cents, :variant_type])
    |> validate_number(:price_cents, greater_than: 0)
    |> validate_number(:stock_quantity, greater_than_or_equal_to: 0)
    |> unique_constraint(:sku)
    |> cast_attributes(attrs)
  end

  defp cast_attributes(changeset, attrs) do
    variant_type = get_field(changeset, :variant_type)
    cast_embed(changeset, :attributes, with: &attribute_changeset(variant_type, &1, &2))
  end

  defp attribute_changeset(:physical, struct, attrs) do
    Catalog.Variant.PhysicalAttributes.changeset(struct || %Catalog.Variant.PhysicalAttributes{}, attrs)
  end

  defp attribute_changeset(:digital, struct, attrs) do
    Catalog.Variant.DigitalAttributes.changeset(struct || %Catalog.Variant.DigitalAttributes{}, attrs)
  end

  defp attribute_changeset(:subscription, struct, attrs) do
    Catalog.Variant.SubscriptionAttributes.changeset(struct || %Catalog.Variant.SubscriptionAttributes{}, attrs)
  end

  defp attribute_changeset(nil, struct, _attrs), do: Ecto.Changeset.change(struct || %{})
end

defmodule Catalog.Variant.Attributes do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  embedded_schema do
    field :raw, :map, default: %{}
  end
end

defmodule Catalog.Variant.PhysicalAttributes do
  @moduledoc "Attributes for physical product variants (clothing, hardware, etc.)."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :size, :string
    field :colour, :string
    field :weight_grams, :integer
    field :dimensions_mm, :map
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = attrs, params) do
    attrs
    |> cast(params, [:size, :colour, :weight_grams, :dimensions_mm])
    |> validate_required([:size])
    |> validate_length(:size, min: 1, max: 20)
    |> validate_length(:colour, max: 50)
    |> validate_number(:weight_grams, greater_than: 0)
  end
end

defmodule Catalog.Variant.DigitalAttributes do
  @moduledoc "Attributes for digital product variants (software, media, etc.)."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :format, Ecto.Enum, values: [:pdf, :epub, :mp3, :mp4, :zip, :iso]
    field :file_size_bytes, :integer
    field :licence_type, Ecto.Enum, values: [:single_user, :team, :enterprise, :perpetual]
    field :download_limit, :integer
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = attrs, params) do
    attrs
    |> cast(params, [:format, :file_size_bytes, :licence_type, :download_limit])
    |> validate_required([:format, :licence_type])
    |> validate_number(:file_size_bytes, greater_than: 0)
    |> validate_number(:download_limit, greater_than: 0)
  end
end

defmodule Catalog.Variant.SubscriptionAttributes do
  @moduledoc "Attributes for subscription product variants."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :billing_interval, Ecto.Enum, values: [:monthly, :quarterly, :annual]
    field :trial_days, :integer, default: 0
    field :seat_limit, :integer
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = attrs, params) do
    attrs
    |> cast(params, [:billing_interval, :trial_days, :seat_limit])
    |> validate_required([:billing_interval])
    |> validate_number(:trial_days, greater_than_or_equal_to: 0)
    |> validate_number(:seat_limit, greater_than: 0)
  end
end
```
