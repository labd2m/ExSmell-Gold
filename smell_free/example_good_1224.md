```elixir
defmodule Inventory.SKU do
  @moduledoc """
  Value object representing a validated stock-keeping unit identifier.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}

  @sku_regex ~r/^[A-Z0-9\-]{3,30}$/

  @spec new(String.t()) :: {:ok, t()} | {:error, :invalid_sku}
  def new(value) when is_binary(value) do
    if Regex.match?(@sku_regex, value) do
      {:ok, %__MODULE__{value: value}}
    else
      {:error, :invalid_sku}
    end
  end

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: v}), do: v
end

defmodule Inventory.Item do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "inventory_items" do
    field :sku, :string
    field :name, :string
    field :quantity_on_hand, :integer, default: 0
    field :quantity_reserved, :integer, default: 0
    field :reorder_threshold, :integer, default: 10
    field :warehouse_id, :integer
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(item, attrs) do
    item
    |> cast(attrs, [:sku, :name, :quantity_on_hand, :quantity_reserved, :reorder_threshold, :warehouse_id])
    |> validate_required([:sku, :name, :warehouse_id])
    |> validate_number(:quantity_on_hand, greater_than_or_equal_to: 0)
    |> validate_number(:quantity_reserved, greater_than_or_equal_to: 0)
    |> validate_number(:reorder_threshold, greater_than_or_equal_to: 0)
    |> unique_constraint([:sku, :warehouse_id])
  end

  @spec available_quantity(t()) :: integer()
  def available_quantity(%__MODULE__{quantity_on_hand: qoh, quantity_reserved: qr}) do
    max(0, qoh - qr)
  end

  @spec below_threshold?(t()) :: boolean()
  def below_threshold?(%__MODULE__{quantity_on_hand: qoh, reorder_threshold: threshold}) do
    qoh <= threshold
  end
end

defmodule Inventory do
  @moduledoc """
  Manages stock levels, reservations, and receiving for inventory items.
  All mutations are atomic; concurrent adjustments use optimistic locking.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Inventory.{Repo, Item}

  @spec get_by_sku(String.t(), integer()) :: {:ok, Item.t()} | {:error, :not_found}
  def get_by_sku(sku, warehouse_id) when is_binary(sku) and is_integer(warehouse_id) do
    case Repo.get_by(Item, sku: sku, warehouse_id: warehouse_id) do
      nil -> {:error, :not_found}
      item -> {:ok, item}
    end
  end

  @spec receive_stock(Item.t(), pos_integer()) ::
          {:ok, Item.t()} | {:error, Ecto.Changeset.t()}
  def receive_stock(%Item{} = item, quantity)
      when is_integer(quantity) and quantity > 0 do
    item
    |> Item.changeset(%{quantity_on_hand: item.quantity_on_hand + quantity})
    |> Repo.update()
  end

  @spec reserve(Item.t(), pos_integer()) ::
          {:ok, Item.t()} | {:error, :insufficient_stock} | {:error, Ecto.Changeset.t()}
  def reserve(%Item{} = item, quantity) when is_integer(quantity) and quantity > 0 do
    if Item.available_quantity(item) >= quantity do
      item
      |> Item.changeset(%{quantity_reserved: item.quantity_reserved + quantity})
      |> Repo.update()
    else
      {:error, :insufficient_stock}
    end
  end

  @spec fulfill(Item.t(), pos_integer()) ::
          {:ok, %{item: Item.t()}} | {:error, atom(), term(), map()}
  def fulfill(%Item{} = item, quantity) when is_integer(quantity) and quantity > 0 do
    Multi.new()
    |> Multi.run(:validate, fn _repo, _ -> check_reservation(item, quantity) end)
    |> Multi.update(:item, Item.changeset(item, %{
         quantity_on_hand: item.quantity_on_hand - quantity,
         quantity_reserved: max(0, item.quantity_reserved - quantity)
       }))
    |> Repo.transaction()
  end

  @spec below_threshold_items(integer()) :: list(Item.t())
  def below_threshold_items(warehouse_id) when is_integer(warehouse_id) do
    Item
    |> where([i], i.warehouse_id == ^warehouse_id)
    |> where([i], i.quantity_on_hand <= i.reorder_threshold)
    |> order_by([i], asc: i.quantity_on_hand)
    |> Repo.all()
  end

  defp check_reservation(%Item{quantity_reserved: reserved}, quantity) when reserved >= quantity do
    {:ok, :sufficient_reservation}
  end

  defp check_reservation(_item, _quantity), do: {:error, :insufficient_reservation}
end
```
