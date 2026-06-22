**File:** `example_good_1347.md`

```elixir
defmodule Store.Orders do
  @moduledoc """
  Context module for managing customer orders.
  All state mutations and queries related to orders are centralized here.
  """

  import Ecto.Query, warn: false

  alias Store.Repo
  alias Store.Orders.{Order, LineItem, StatusTransition}

  @type order_params :: %{
          customer_id: pos_integer(),
          line_items: [line_item_params()]
        }

  @type line_item_params :: %{
          product_id: pos_integer(),
          quantity: pos_integer(),
          unit_price_cents: pos_integer()
        }

  @spec create_order(order_params()) :: {:ok, Order.t()} | {:error, Ecto.Changeset.t()}
  def create_order(params) do
    %Order{}
    |> Order.creation_changeset(params)
    |> Repo.insert()
  end

  @spec get_order(pos_integer()) :: {:ok, Order.t()} | {:error, :not_found}
  def get_order(id) do
    case Repo.get(Order, id) do
      nil -> {:error, :not_found}
      order -> {:ok, Repo.preload(order, :line_items)}
    end
  end

  @spec list_orders_for_customer(pos_integer()) :: [Order.t()]
  def list_orders_for_customer(customer_id) do
    Order
    |> where([o], o.customer_id == ^customer_id)
    |> order_by([o], desc: o.inserted_at)
    |> preload(:line_items)
    |> Repo.all()
  end

  @spec transition_status(Order.t(), Order.status()) ::
          {:ok, Order.t()} | {:error, :invalid_transition} | {:error, Ecto.Changeset.t()}
  def transition_status(%Order{} = order, new_status) do
    if StatusTransition.allowed?(order.status, new_status) do
      order
      |> Order.status_changeset(%{status: new_status})
      |> Repo.update()
    else
      {:error, :invalid_transition}
    end
  end

  @spec cancel_order(Order.t()) ::
          {:ok, Order.t()} | {:error, :invalid_transition} | {:error, Ecto.Changeset.t()}
  def cancel_order(%Order{} = order), do: transition_status(order, :cancelled)
end

defmodule Store.Orders.Order do
  @moduledoc "Schema and changeset functions for a customer order."

  use Ecto.Schema
  import Ecto.Changeset

  alias Store.Orders.LineItem

  @type status :: :pending | :confirmed | :shipped | :delivered | :cancelled

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          customer_id: pos_integer(),
          status: status(),
          total_cents: non_neg_integer(),
          line_items: [LineItem.t()] | Ecto.Association.NotLoaded.t()
        }

  schema "orders" do
    field :customer_id, :integer
    field :status, Ecto.Enum, values: [:pending, :confirmed, :shipped, :delivered, :cancelled]
    field :total_cents, :integer, default: 0
    has_many :line_items, LineItem
    timestamps()
  end

  @spec creation_changeset(t(), map()) :: Ecto.Changeset.t()
  def creation_changeset(order, params) do
    order
    |> cast(params, [:customer_id])
    |> validate_required([:customer_id])
    |> validate_number(:customer_id, greater_than: 0)
    |> put_change(:status, :pending)
    |> cast_assoc(:line_items, with: &LineItem.changeset/2, required: true)
    |> compute_total()
  end

  @spec status_changeset(t(), map()) :: Ecto.Changeset.t()
  def status_changeset(order, params) do
    order
    |> cast(params, [:status])
    |> validate_required([:status])
  end

  defp compute_total(%Ecto.Changeset{} = changeset) do
    items = get_field(changeset, :line_items) || []

    total =
      Enum.reduce(items, 0, fn item, acc ->
        acc + item.quantity * item.unit_price_cents
      end)

    put_change(changeset, :total_cents, total)
  end
end

defmodule Store.Orders.StatusTransition do
  @moduledoc "Encapsulates allowed status transition rules for orders."

  @allowed_transitions %{
    pending: [:confirmed, :cancelled],
    confirmed: [:shipped, :cancelled],
    shipped: [:delivered],
    delivered: [],
    cancelled: []
  }

  @spec allowed?(Store.Orders.Order.status(), Store.Orders.Order.status()) :: boolean()
  def allowed?(from, to) do
    @allowed_transitions
    |> Map.get(from, [])
    |> Enum.member?(to)
  end
end
```
