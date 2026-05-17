```elixir
# ── file: lib/orders/processor.ex ───────────────────────────────────────────


defmodule Orders.Processor do
  @moduledoc """
  Handles the full lifecycle of customer orders from submission to fulfilment.
  Defined in `lib/orders/processor.ex`.
  """

  alias Orders.{OrderStore, StatusLog, PaymentCoordinator, FulfilmentRouter}
  alias Orders.Schema.Order

  @terminal_statuses [:delivered, :cancelled, :refunded]

  @type order_id :: String.t()

  @doc """
  Submit a new order, triggering payment authorisation.
  Returns `{:ok, order}` with status `:pending_payment`.
  """
  @spec submit(Order.t()) :: {:ok, Order.t()} | {:error, String.t()}
  def submit(%Order{status: :draft} = order) do
    with :ok <- validate_order(order),
         {:ok, auth_ref} <- PaymentCoordinator.authorize(order) do
      updated = transition(order, :pending_payment, %{auth_ref: auth_ref})
      StatusLog.append(updated.id, :pending_payment, "Order submitted")
      {:ok, updated}
    end
  end

  def submit(%Order{status: status}) do
    {:error, "Cannot submit order in status: #{status}"}
  end

  @doc "Confirm payment captured; advance order to :confirmed."
  @spec confirm(order_id()) :: {:ok, Order.t()} | {:error, String.t()}
  def confirm(order_id) do
    with {:ok, order} <- OrderStore.fetch(order_id),
         :ok <- check_status(order, :pending_payment),
         {:ok, _} <- PaymentCoordinator.capture(order.auth_ref) do
      updated = transition(order, :confirmed, %{})
      StatusLog.append(order_id, :confirmed, "Payment captured")
      {:ok, updated}
    end
  end

  @doc "Cancel an order before it enters fulfilment."
  @spec cancel(order_id(), String.t()) :: {:ok, Order.t()} | {:error, String.t()}
  def cancel(order_id, reason) do
    with {:ok, order} <- OrderStore.fetch(order_id),
         :ok <- check_not_terminal(order) do
      if order.status in [:pending_payment, :confirmed] do
        PaymentCoordinator.void(order.auth_ref)
        updated = transition(order, :cancelled, %{cancel_reason: reason})
        StatusLog.append(order_id, :cancelled, reason)
        {:ok, updated}
      else
        {:error, "Order cannot be cancelled in status: #{order.status}"}
      end
    end
  end

  @doc "Hand off a confirmed order to the fulfilment router."
  @spec fulfil(order_id()) :: {:ok, Order.t()} | {:error, String.t()}
  def fulfil(order_id) do
    with {:ok, order} <- OrderStore.fetch(order_id),
         :ok <- check_status(order, :confirmed),
         {:ok, tracking} <- FulfilmentRouter.dispatch(order) do
      updated = transition(order, :in_fulfilment, %{tracking: tracking})
      StatusLog.append(order_id, :in_fulfilment, "Dispatched to warehouse")
      {:ok, updated}
    end
  end

  @doc "Return the full status history for an order."
  @spec status_history(order_id()) :: {:ok, [map()]} | {:error, String.t()}
  def status_history(order_id) do
    case StatusLog.fetch_all(order_id) do
      {:ok, logs} -> {:ok, Enum.sort_by(logs, & &1.occurred_at)}
      :not_found -> {:error, "No history for order: #{order_id}"}
    end
  end

  defp transition(order, new_status, meta) do
    updated = %{order | status: new_status, updated_at: DateTime.utc_now()}
    updated = Map.merge(updated, meta)
    {:ok, saved} = OrderStore.save(updated)
    saved
  end

  defp validate_order(%Order{line_items: []}), do: {:error, "Order has no line items"}
  defp validate_order(%Order{customer_id: nil}), do: {:error, "Order has no customer"}
  defp validate_order(_), do: :ok

  defp check_status(%{status: s}, expected) when s == expected, do: :ok
  defp check_status(%{status: s}, expected), do: {:error, "Expected #{expected}, got #{s}"}

  defp check_not_terminal(%{status: s}) when s in @terminal_statuses do
    {:error, "Order is in terminal status: #{s}"}
  end

  defp check_not_terminal(_), do: :ok
end


# ── file: lib/orders/processor_notifications.ex ─────────────────────────────────────────────────────


defmodule Orders.Processor do
  @moduledoc """
  Notification hooks triggered by order lifecycle transitions.
  """

  alias Orders.{OrderStore, NotificationBus}

  @doc "Send a confirmation email when an order is confirmed."
  @spec on_confirm(String.t()) :: :ok
  def on_confirm(order_id) do
    with {:ok, order} <- OrderStore.fetch(order_id) do
      NotificationBus.publish(:order_confirmed, %{
        order_id: order_id,
        customer_id: order.customer_id,
        total: order.total_cents
      })
    end
  end

  @doc "Notify the customer when their order ships."
  @spec on_fulfil(String.t()) :: :ok
  def on_fulfil(order_id) do
    with {:ok, order} <- OrderStore.fetch(order_id) do
      NotificationBus.publish(:order_shipped, %{
        order_id: order_id,
        customer_id: order.customer_id,
        tracking: order.tracking
      })
    end
  end

  @doc "Notify the customer when their order is cancelled."
  @spec on_cancel(String.t(), String.t()) :: :ok
  def on_cancel(order_id, reason) do
    with {:ok, order} <- OrderStore.fetch(order_id) do
      NotificationBus.publish(:order_cancelled, %{
        order_id: order_id,
        customer_id: order.customer_id,
        reason: reason
      })
    end
  end

  @doc "Emit a Telemetry event for order state transitions."
  @spec emit_transition(String.t(), atom(), atom()) :: :ok
  def emit_transition(order_id, from_status, to_status) do
    :telemetry.execute(
      [:orders, :transition],
      %{count: 1},
      %{order_id: order_id, from: from_status, to: to_status}
    )
  end
end

```
