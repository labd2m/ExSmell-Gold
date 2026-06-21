```elixir
defmodule Orders.Fulfillment do
  @moduledoc """
  Orchestrates the order fulfillment lifecycle: payment capture, inventory
  reservation, shipment dispatch, and customer notification. Each stage is
  delegated to a focused service module. The pipeline stops at the first
  failure and returns a typed error so callers can respond without
  catching exceptions.
  """

  require Logger

  alias Orders.{Repository, FulfillmentRecord}
  alias Inventory.Allocator
  alias Payments.Capturer
  alias Shipping.Dispatcher
  alias Notifications.Dispatcher, as: Notify

  @type order_id :: String.t()
  @type fulfillment_error ::
          :order_not_found
          | :already_fulfilled
          | :payment_capture_failed
          | :insufficient_inventory
          | :shipment_dispatch_failed
          | :persistence_failed

  @type fulfillment_success :: %{
          order_id: String.t(),
          tracking_number: String.t(),
          fulfilled_at: DateTime.t()
        }

  @type fulfillment_result :: {:ok, fulfillment_success()} | {:error, fulfillment_error()}

  @doc """
  Fulfills the order identified by `order_id`. Runs payment capture, inventory
  allocation, and shipment creation in sequence. Returns the tracking number
  and fulfillment timestamp on success.
  """
  @spec fulfill(order_id()) :: fulfillment_result()
  def fulfill(order_id) when is_binary(order_id) do
    with {:ok, order} <- Repository.fetch_unfulfilled(order_id),
         {:ok, capture} <- Capturer.capture_authorization(order.payment_auth_id),
         {:ok, allocation} <- Allocator.reserve_items(order.line_items),
         {:ok, shipment} <- Dispatcher.create_shipment(order, allocation),
         {:ok, record} <- persist_fulfillment(order, capture, allocation, shipment) do
      notify_customer(order, record)
      log_completion(order_id, record.tracking_number)
      {:ok, build_result(record)}
    end
  end

  defp persist_fulfillment(order, capture, allocation, shipment) do
    attrs = %{
      order_id: order.id,
      payment_id: capture.payment_id,
      allocation_ref: allocation.reference,
      tracking_number: shipment.tracking_number,
      fulfilled_at: DateTime.utc_now()
    }

    case Repository.create_fulfillment_record(attrs) do
      {:ok, record} -> {:ok, record}
      {:error, _changeset} -> {:error, :persistence_failed}
    end
  end

  defp notify_customer(order, record) do
    Notify.dispatch(%{
      type: :order_shipped,
      recipient_id: order.customer_id,
      payload: %{
        order_id: order.id,
        tracking_number: record.tracking_number,
        fulfilled_at: DateTime.to_iso8601(record.fulfilled_at)
      }
    })
  end

  defp build_result(%FulfillmentRecord{} = record) do
    %{
      order_id: record.order_id,
      tracking_number: record.tracking_number,
      fulfilled_at: record.fulfilled_at
    }
  end

  defp log_completion(order_id, tracking_number) do
    Logger.info("[Orders.Fulfillment] #{order_id} fulfilled → #{tracking_number}")
  end
end
```
