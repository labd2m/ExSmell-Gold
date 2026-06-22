```elixir
defmodule Commerce.Orders do
  @moduledoc """
  Context managing the full lifecycle of customer orders from placement
  through fulfillment and cancellation.

  All order state transitions are validated against the order's current
  status before any database write is attempted. Multi-step operations
  that affect inventory or payments are wrapped in a single database
  transaction to guarantee consistency.
  """

  import Ecto.Query, warn: false

  alias Commerce.Repo
  alias Commerce.Orders.{Order, LineItem}
  alias Commerce.Inventory
  alias Commerce.Payments

  @type place_params :: %{
          required(:customer_id) => Ecto.UUID.t(),
          required(:items) => [%{product_id: Ecto.UUID.t(), quantity: pos_integer()}]
        }

  @doc "Returns all orders for a customer ordered by newest first."
  @spec list_for_customer(Ecto.UUID.t()) :: [Order.t()]
  def list_for_customer(customer_id) when is_binary(customer_id) do
    Order
    |> where([o], o.customer_id == ^customer_id)
    |> preload(:line_items)
    |> order_by([o], desc: o.inserted_at)
    |> Repo.all()
  end

  @doc "Fetches a single order by ID with preloaded line items."
  @spec get_order(Ecto.UUID.t()) :: {:ok, Order.t()} | {:error, :not_found}
  def get_order(id) when is_binary(id) do
    case Repo.get(Order, id) do
      nil -> {:error, :not_found}
      %Order{} = order -> {:ok, Repo.preload(order, :line_items)}
    end
  end

  @doc """
  Places a new order after verifying inventory availability.

  All line items and the order record are persisted atomically. Returns
  `{:error, reason}` and rolls back if inventory reservation fails.
  """
  @spec place_order(place_params()) :: {:ok, Order.t()} | {:error, term()}
  def place_order(%{customer_id: _, items: _} = params) do
    Repo.transaction(fn ->
      with {:ok, reserved} <- Inventory.reserve_items(params.items),
           {:ok, order} <- insert_order(params, reserved) do
        order
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Cancels an order in `:pending` or `:confirmed` status.

  Releases inventory reservations and initiates a refund when applicable.
  Returns `{:error, :not_cancellable}` for orders that cannot be cancelled.
  """
  @spec cancel_order(Order.t()) :: {:ok, Order.t()} | {:error, :not_cancellable | term()}
  def cancel_order(%Order{status: status} = order) when status in [:pending, :confirmed] do
    Repo.transaction(fn ->
      with {:ok, _} <- Inventory.release_items(order.line_items),
           {:ok, _} <- Payments.refund_if_charged(order),
           {:ok, cancelled} <- update_order_status(order, :cancelled) do
        cancelled
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def cancel_order(%Order{}), do: {:error, :not_cancellable}

  @doc "Marks a confirmed order as shipped and records the tracking reference."
  @spec mark_shipped(Order.t(), String.t()) ::
          {:ok, Order.t()} | {:error, :not_shippable | Ecto.Changeset.t()}
  def mark_shipped(%Order{status: :confirmed} = order, tracking_ref)
      when is_binary(tracking_ref) do
    order
    |> Order.shipment_changeset(%{tracking_ref: tracking_ref, status: :shipped})
    |> Repo.update()
  end

  def mark_shipped(%Order{}, _tracking_ref), do: {:error, :not_shippable}

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp insert_order(params, reserved_items) do
    total_cents = compute_total_cents(reserved_items)

    %Order{}
    |> Order.changeset(%{customer_id: params.customer_id, status: :pending, total_cents: total_cents})
    |> Ecto.Changeset.put_assoc(:line_items, build_line_items(reserved_items))
    |> Repo.insert()
  end

  defp build_line_items(items) do
    Enum.map(items, fn item ->
      %LineItem{
        product_id: item.product_id,
        quantity: item.quantity,
        unit_price_cents: item.unit_price_cents
      }
    end)
  end

  defp compute_total_cents(items) do
    Enum.reduce(items, 0, fn item, acc -> acc + item.unit_price_cents * item.quantity end)
  end

  defp update_order_status(order, status) do
    order
    |> Order.status_changeset(%{status: status})
    |> Repo.update()
  end
end
```
