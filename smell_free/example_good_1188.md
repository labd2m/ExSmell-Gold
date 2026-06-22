```elixir
defmodule Store.Orders.Order do
  @moduledoc """
  Schema and changeset for the orders table.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @valid_statuses ~w(pending confirmed shipped cancelled)

  schema "orders" do
    field :status, :string, default: "pending"
    field :total_cents, :integer, default: 0
    belongs_to :customer, Store.Customers.Customer
    has_many :line_items, Store.Orders.LineItem
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(order, attrs) do
    order
    |> cast(attrs, [:status, :total_cents, :customer_id])
    |> validate_required([:customer_id])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:total_cents, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:customer_id)
  end
end

defmodule Store.Orders do
  @moduledoc """
  Context for managing customer orders.
  All order-related database interactions are centralized here.
  """

  import Ecto.Query, warn: false

  alias Store.Repo
  alias Store.Orders.Order

  @type create_attrs :: %{required(:customer_id) => integer(), optional(:total_cents) => integer()}
  @type update_attrs :: %{optional(:status) => String.t(), optional(:total_cents) => integer()}

  @spec list_for_customer(integer()) :: list(Order.t())
  def list_for_customer(customer_id) when is_integer(customer_id) do
    Order
    |> where([o], o.customer_id == ^customer_id)
    |> order_by([o], desc: o.inserted_at)
    |> preload(:line_items)
    |> Repo.all()
  end

  @spec get(integer()) :: {:ok, Order.t()} | {:error, :not_found}
  def get(id) when is_integer(id) do
    case Repo.get(Order, id) do
      nil -> {:error, :not_found}
      order -> {:ok, Repo.preload(order, :line_items)}
    end
  end

  @spec create(create_attrs()) :: {:ok, Order.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    %Order{}
    |> Order.changeset(attrs)
    |> Repo.insert()
  end

  @spec confirm(Order.t()) :: {:ok, Order.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def confirm(%Order{status: "pending"} = order) do
    order |> Order.changeset(%{status: "confirmed"}) |> Repo.update()
  end

  def confirm(%Order{}), do: {:error, :invalid_transition}

  @spec ship(Order.t()) :: {:ok, Order.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def ship(%Order{status: "confirmed"} = order) do
    order |> Order.changeset(%{status: "shipped"}) |> Repo.update()
  end

  def ship(%Order{}), do: {:error, :invalid_transition}

  @spec cancel(Order.t()) ::
          {:ok, Order.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def cancel(%Order{status: status} = order) when status in ["pending", "confirmed"] do
    order |> Order.changeset(%{status: "cancelled"}) |> Repo.update()
  end

  def cancel(%Order{}), do: {:error, :invalid_transition}

  @spec count_by_status() :: %{String.t() => integer()}
  def count_by_status do
    Order
    |> group_by([o], o.status)
    |> select([o], {o.status, count(o.id)})
    |> Repo.all()
    |> Map.new()
  end

  @spec pending() :: list(Order.t())
  def pending do
    Order
    |> where([o], o.status == "pending")
    |> order_by([o], asc: o.inserted_at)
    |> Repo.all()
  end

  @spec total_revenue_cents() :: integer()
  def total_revenue_cents do
    Order
    |> where([o], o.status in ["confirmed", "shipped"])
    |> select([o], sum(o.total_cents))
    |> Repo.one()
    |> Kernel.||(0)
  end
end
```
