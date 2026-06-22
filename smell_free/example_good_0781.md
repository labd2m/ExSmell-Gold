```elixir
defmodule Commerce.OrderFulfillmentPipeline do
  @moduledoc """
  Executes the post-payment order fulfilment pipeline: inventory reservation,
  shipment label creation, and customer notification. Each step is delegated
  to a focused context module and the pipeline halts with a typed error at
  the first failure. The pipeline is idempotent via the order ID so it is
  safe to re-run after partial failures once the root cause is resolved.
  """

  require Logger

  alias Inventory.LotTracker
  alias Shipping.LabelContext
  alias Notifications.Dispatcher, as: Notify
  alias Orders.Repository, as: OrderRepo

  @type order_id :: String.t()
  @type fulfil_result ::
          {:ok, %{tracking_number: String.t(), fulfilled_at: DateTime.t()}}
          | {:error,
             :order_not_found
             | :already_fulfilled
             | :insufficient_stock
             | :label_creation_failed}

  @doc """
  Runs the fulfilment pipeline for `order_id`. Returns the tracking number
  and fulfilment timestamp on success, or a typed error on failure.
  """
  @spec fulfil(order_id()) :: fulfil_result()
  def fulfil(order_id) when is_binary(order_id) do
    with {:ok, order} <- fetch_unfulfilled(order_id),
         {:ok, allocations} <- reserve_inventory(order),
         {:ok, label} <- create_label(order, allocations),
         {:ok, _order} <- mark_fulfilled(order, label.tracking_number) do
      notify_customer(order, label.tracking_number)
      log_completion(order_id, label.tracking_number)
      {:ok, %{tracking_number: label.tracking_number, fulfilled_at: DateTime.utc_now()}}
    end
  end

  defp fetch_unfulfilled(order_id) do
    case OrderRepo.fetch(order_id) do
      {:ok, %{status: "fulfilled"}} -> {:error, :already_fulfilled}
      {:ok, order} -> {:ok, order}
      {:error, :not_found} -> {:error, :order_not_found}
    end
  end

  defp reserve_inventory(order) do
    results =
      Enum.reduce_while(order.line_items, {:ok, []}, fn item, {:ok, acc} ->
        case LotTracker.allocate(item.sku, item.quantity, order.id) do
          {:ok, allocs} -> {:cont, {:ok, acc ++ allocs}}
          {:error, :insufficient_stock} -> {:halt, {:error, :insufficient_stock}}
          {:error, _} -> {:halt, {:error, :insufficient_stock}}
        end
      end)

    results
  end

  defp create_label(order, _allocations) do
    params = %{
      recipient: order.shipping_address,
      weight_grams: total_weight(order.line_items),
      service_class: order.shipping_service || :standard
    }

    case LabelContext.create(params) do
      {:ok, label} -> {:ok, label}
      {:error, _} -> {:error, :label_creation_failed}
    end
  end

  defp mark_fulfilled(order, tracking_number) do
    OrderRepo.update(order, %{
      status: "fulfilled",
      tracking_number: tracking_number,
      fulfilled_at: DateTime.utc_now()
    })
  end

  defp notify_customer(order, tracking_number) do
    Notify.dispatch(%{
      type: :order_shipped,
      recipient_id: order.customer_id,
      payload: %{order_id: order.id, tracking_number: tracking_number}
    })
  end

  defp total_weight(line_items) do
    Enum.sum_by(line_items, fn i -> Map.get(i, :weight_grams, 0) * i.quantity end)
  end

  defp log_completion(order_id, tracking_number) do
    Logger.info("[FulfillmentPipeline] #{order_id} fulfilled → #{tracking_number}")
  end
end
```
