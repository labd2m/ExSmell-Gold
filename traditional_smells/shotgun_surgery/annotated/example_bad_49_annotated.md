# Smell: Shotgun Surgery

- **Smell Name:** Shotgun Surgery
- **Expected Smell Location:** `MyApp.Orders.Processor`, `MyApp.Orders.FulfillmentHandler`, `MyApp.Orders.StatusNotifier`
- **Affected Functions:** `Processor.process/2`, `FulfillmentHandler.fulfill/1`, `StatusNotifier.notify_placed/1`
- **Explanation:** Adding a new order type (e.g., `:preorder`) requires small but mandatory changes in all three modules: validation and creation logic in `Processor`, fulfillment routing in `FulfillmentHandler`, and notification messaging in `StatusNotifier`. Order-type knowledge is distributed across modules rather than owned in one place.

```elixir
# VALIDATION: SMELL START - Shotgun Surgery
# VALIDATION: This is a smell because a new order type (e.g., :preorder) mandates
# VALIDATION: simultaneous changes in Processor.process/2 (validation and creation),
# VALIDATION: FulfillmentHandler.fulfill/1 (warehouse routing), and
# VALIDATION: StatusNotifier.notify_placed/1 (customer messaging). All three modules
# VALIDATION: must be updated together, spreading order-type responsibility widely.

defmodule MyApp.Orders.Processor do
  @moduledoc """
  Validates and creates orders based on their type.
  Each order type has distinct validation rules, inventory locking strategies,
  and pricing pipelines applied before the order record is persisted.
  """

  alias MyApp.Orders.{PricingPipeline, InventoryLocker, FulfillmentHandler, StatusNotifier}
  alias MyApp.Repo

  require Logger

  def process(%{type: :regular} = order_params, customer) do
    with :ok <- validate_regular_order(order_params),
         {:ok, priced} <- PricingPipeline.apply(:regular, order_params, customer),
         {:ok, locked} <- InventoryLocker.lock(priced.line_items),
         {:ok, order} <- Repo.insert(build_order(:regular, priced, customer, locked)) do
      StatusNotifier.notify_placed(order)
      FulfillmentHandler.fulfill(order)
      Logger.info("Regular order placed", order_id: order.id, customer_id: customer.id)
      {:ok, order}
    else
      {:error, :inventory_unavailable} -> {:error, :items_out_of_stock}
      {:error, reason} -> {:error, reason}
    end
  end

  def process(%{type: :express} = order_params, customer) do
    with :ok <- validate_express_order(order_params, customer),
         {:ok, priced} <- PricingPipeline.apply(:express, order_params, customer),
         {:ok, locked} <- InventoryLocker.lock_priority(priced.line_items),
         {:ok, order} <- Repo.insert(build_order(:express, priced, customer, locked)) do
      StatusNotifier.notify_placed(order)
      FulfillmentHandler.fulfill(order)
      Logger.info("Express order placed", order_id: order.id, customer_id: customer.id)
      {:ok, order}
    else
      {:error, :express_not_available} -> {:error, :express_shipping_unavailable_for_location}
      {:error, :inventory_unavailable} -> {:error, :items_out_of_stock}
      {:error, reason} -> {:error, reason}
    end
  end

  def process(%{type: :scheduled} = order_params, customer) do
    with :ok <- validate_scheduled_order(order_params),
         {:ok, priced} <- PricingPipeline.apply(:scheduled, order_params, customer),
         {:ok, order} <- Repo.insert(build_order(:scheduled, priced, customer, nil)) do
      StatusNotifier.notify_placed(order)
      FulfillmentHandler.fulfill(order)
      Logger.info("Scheduled order placed",
        order_id: order.id,
        delivery_date: order_params.requested_delivery_date
      )
      {:ok, order}
    else
      {:error, :slot_unavailable} -> {:error, :requested_delivery_slot_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  def process(%{type: unknown}, _customer) do
    {:error, {:unsupported_order_type, unknown}}
  end

  defp validate_regular_order(%{line_items: items}) when length(items) > 0, do: :ok
  defp validate_regular_order(_), do: {:error, :empty_order}

  defp validate_express_order(%{shipping_address: %{zip_code: zip}}, _customer) do
    if MyApp.Shipping.express_available?(zip), do: :ok, else: {:error, :express_not_available}
  end

  defp validate_scheduled_order(%{requested_delivery_date: date}) do
    if Date.diff(date, Date.utc_today()) >= 2, do: :ok, else: {:error, :slot_unavailable}
  end

  defp build_order(type, priced, customer, lock_ref) do
    %MyApp.Orders.Order{
      type: type,
      customer_id: customer.id,
      line_items: priced.line_items,
      subtotal: priced.subtotal,
      discount: priced.discount,
      shipping_fee: priced.shipping_fee,
      total: priced.total,
      inventory_lock_ref: lock_ref,
      status: :confirmed
    }
  end
end

defmodule MyApp.Orders.FulfillmentHandler do
  @moduledoc """
  Routes confirmed orders to the appropriate fulfillment workflow.
  Each order type follows a different warehouse path, SLA, and dispatch queue.
  """

  alias MyApp.Warehouse.{StandardQueue, PriorityQueue, ScheduledQueue}

  def fulfill(%{type: :regular} = order) do
    job_params = %{
      order_id: order.id,
      sla_hours: 72,
      queue: :standard,
      pick_strategy: :nearest_bin
    }

    case StandardQueue.enqueue(job_params) do
      {:ok, job} ->
        update_fulfillment_status(order, :queued, job.id)
        {:ok, :queued}

      {:error, reason} ->
        {:error, {:fulfillment_enqueue_failed, reason}}
    end
  end

  def fulfill(%{type: :express} = order) do
    job_params = %{
      order_id: order.id,
      sla_hours: 4,
      queue: :priority,
      pick_strategy: :fastest_route,
      courier_type: :bike_courier
    }

    case PriorityQueue.enqueue(job_params) do
      {:ok, job} ->
        update_fulfillment_status(order, :queued_priority, job.id)
        {:ok, :queued_priority}

      {:error, reason} ->
        {:error, {:fulfillment_enqueue_failed, reason}}
    end
  end

  def fulfill(%{type: :scheduled} = order) do
    job_params = %{
      order_id: order.id,
      deliver_on: order.requested_delivery_date,
      queue: :scheduled,
      pick_strategy: :batch_by_zone
    }

    case ScheduledQueue.enqueue(job_params) do
      {:ok, job} ->
        update_fulfillment_status(order, :scheduled, job.id)
        {:ok, :scheduled}

      {:error, reason} ->
        {:error, {:fulfillment_enqueue_failed, reason}}
    end
  end

  def fulfill(%{type: unknown}) do
    {:error, {:unsupported_order_type, unknown}}
  end

  defp update_fulfillment_status(order, status, job_id) do
    MyApp.Repo.update_all(
      MyApp.Orders.Order,
      [set: [fulfillment_status: status, fulfillment_job_id: job_id]],
      where: [id: order.id]
    )
  end
end

defmodule MyApp.Orders.StatusNotifier do
  @moduledoc """
  Sends order confirmation notifications to customers.
  Messaging and channel selection vary by order type to reflect
  the different expectations and urgency of each order category.
  """

  alias MyApp.Notifications.Dispatcher

  def notify_placed(%{type: :regular} = order) do
    Dispatcher.dispatch(%{
      type: :order_confirmed,
      channel: :email,
      recipient_id: order.customer_id,
      recipient_email: order.customer.email,
      order_id: order.id,
      estimated_delivery: "3–5 business days",
      total: order.total
    })
  end

  def notify_placed(%{type: :express} = order) do
    Dispatcher.dispatch(%{
      type: :order_confirmed,
      channel: :sms,
      recipient_id: order.customer_id,
      phone_number: order.customer.phone,
      order_id: order.id,
      estimated_delivery: "Within 4 hours",
      total: order.total
    })

    Dispatcher.dispatch(%{
      type: :order_confirmed,
      channel: :email,
      recipient_id: order.customer_id,
      recipient_email: order.customer.email,
      order_id: order.id,
      estimated_delivery: "Within 4 hours",
      total: order.total
    })
  end

  def notify_placed(%{type: :scheduled} = order) do
    Dispatcher.dispatch(%{
      type: :order_scheduled,
      channel: :email,
      recipient_id: order.customer_id,
      recipient_email: order.customer.email,
      order_id: order.id,
      delivery_date: order.requested_delivery_date,
      total: order.total
    })
  end

  def notify_placed(%{type: unknown}) do
    {:error, {:unsupported_order_type, unknown}}
  end
end
# VALIDATION: SMELL END
```
