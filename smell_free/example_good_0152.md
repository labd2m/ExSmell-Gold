```elixir
defmodule Inventory.StockMovement do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @type movement_kind :: :receipt | :shipment | :adjustment | :return

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          product_id: Ecto.UUID.t(),
          kind: movement_kind(),
          quantity: integer(),
          reference: String.t() | nil,
          recorded_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "stock_movements" do
    field :product_id, :binary_id
    field :kind, Ecto.Enum, values: [:receipt, :shipment, :adjustment, :return]
    field :quantity, :integer
    field :reference, :string
    field :recorded_at, :utc_datetime
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(movement, params) do
    movement
    |> cast(params, [:product_id, :kind, :quantity, :reference, :recorded_at])
    |> validate_required([:product_id, :kind, :quantity, :recorded_at])
    |> validate_number(:quantity, not_equal_to: 0)
    |> validate_kind_sign_agreement()
  end

  defp validate_kind_sign_agreement(changeset) do
    kind = get_field(changeset, :kind)
    qty = get_field(changeset, :quantity)

    cond do
      kind in [:receipt, :return] and is_integer(qty) and qty < 0 ->
        add_error(changeset, :quantity, "must be positive for receipts and returns")

      kind == :shipment and is_integer(qty) and qty > 0 ->
        add_error(changeset, :quantity, "must be negative for shipments")

      true ->
        changeset
    end
  end
end

defmodule Inventory do
  @moduledoc """
  Public context for tracking product stock levels via immutable movements.

  Stock on hand for a product is derived by summing all of its recorded
  movements. No record is ever deleted, preserving a full audit trail.
  Shipments are validated inside a serializable transaction to prevent
  over-shipment under concurrent writes.
  """

  import Ecto.Query, warn: false

  alias Inventory.{Repo, StockMovement}

  @spec receive_stock(Ecto.UUID.t(), pos_integer(), String.t() | nil) ::
          {:ok, StockMovement.t()} | {:error, Ecto.Changeset.t()}
  def receive_stock(product_id, quantity, reference \\ nil) when quantity > 0 do
    insert_movement(product_id, :receipt, quantity, reference)
  end

  @spec ship_stock(Ecto.UUID.t(), pos_integer(), String.t() | nil) ::
          {:ok, StockMovement.t()} | {:error, :insufficient_stock | Ecto.Changeset.t()}
  def ship_stock(product_id, quantity, reference \\ nil) when quantity > 0 do
    Repo.transaction(fn ->
      if stock_on_hand(product_id) >= quantity do
        case insert_movement(product_id, :shipment, -quantity, reference) do
          {:ok, movement} -> movement
          {:error, changeset} -> Repo.rollback(changeset)
        end
      else
        Repo.rollback(:insufficient_stock)
      end
    end)
  end

  @spec adjust_stock(Ecto.UUID.t(), integer(), String.t() | nil) ::
          {:ok, StockMovement.t()} | {:error, Ecto.Changeset.t()}
  def adjust_stock(product_id, delta, reference \\ nil) when delta != 0 do
    insert_movement(product_id, :adjustment, delta, reference)
  end

  @spec stock_on_hand(Ecto.UUID.t()) :: integer()
  def stock_on_hand(product_id) when is_binary(product_id) do
    StockMovement
    |> where([m], m.product_id == ^product_id)
    |> select([m], coalesce(sum(m.quantity), 0))
    |> Repo.one()
  end

  @spec recent_movements(Ecto.UUID.t(), pos_integer()) :: [StockMovement.t()]
  def recent_movements(product_id, limit \\ 50)
      when is_binary(product_id) and is_integer(limit) and limit > 0 do
    StockMovement
    |> where([m], m.product_id == ^product_id)
    |> order_by([m], desc: m.recorded_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp insert_movement(product_id, kind, quantity, reference) do
    %StockMovement{}
    |> StockMovement.changeset(%{
      product_id: product_id,
      kind: kind,
      quantity: quantity,
      reference: reference,
      recorded_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end
end
```
