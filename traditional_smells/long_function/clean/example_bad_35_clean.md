```elixir
defmodule Commerce.FulfillmentPipeline do
  @moduledoc """
  Drives end-to-end order fulfillment from payment capture
  through warehouse dispatch and customer notification.
  """

  require Logger

  alias Commerce.{
    Order, PaymentGateway, FraudReview, StockAllocator,
    Warehouse, PickList, PackingSlip, CarrierAPI, Mailer
  }

  @hold_review_timeout_hrs 4

  def fulfill_order(%Order{} = order, opts \\ []) do
    operator = Keyword.get(opts, :operator, "system")
    Logger.info("Fulfilling order #{order.id} — operator: #{operator}")

    # 1. Capture authorised payment
    case PaymentGateway.capture(order.payment_intent_id, order.total_cents) do
      {:error, reason} ->
        Logger.error("Payment capture failed for order #{order.id}: #{inspect(reason)}")
        Order.update_status(order.id, :payment_failed)
        {:error, :payment_capture_failed}

      {:ok, charge} ->
        Order.update_payment_reference(order.id, charge.id)

        # 2. Check and resolve fraud hold
        fraud_status = FraudReview.status_for_order(order.id)

        case fraud_status do
          :blocked ->
            Logger.warning("Order #{order.id} blocked by fraud review")
            Order.update_status(order.id, :fraud_blocked)
            {:error, :fraud_blocked}

          :under_review ->
            age_hours = DateTime.diff(DateTime.utc_now(), order.inserted_at, :second) / 3600

            if age_hours < @hold_review_timeout_hrs do
              Logger.info("Order #{order.id} still under fraud review — deferring")
              {:deferred, :fraud_review_pending}
            else
              Logger.warning("Order #{order.id} fraud review timed out — proceeding")
              FraudReview.mark_resolved(order.id, :timeout_approved)
              :proceed
            end

          _ ->
            :proceed
        end

        # 3. Allocate stock for each line item
        allocation_result =
          Enum.reduce_while(order.line_items, {:ok, []}, fn item, {:ok, acc} ->
            case StockAllocator.allocate(item.sku, item.quantity, order.id) do
              {:ok, alloc}     -> {:cont, {:ok, [alloc | acc]}}
              {:error, reason} -> {:halt, {:error, {item.sku, reason}}}
            end
          end)

        case allocation_result do
          {:error, {sku, reason}} ->
            Logger.error("Stock allocation failed for SKU #{sku}: #{inspect(reason)}")
            Order.update_status(order.id, :allocation_failed)
            {:error, {:stock_unavailable, sku}}

          {:ok, allocations} ->
            # 4. Select fulfilling warehouse
            warehouse =
              Warehouse.best_for_order(order.shipping_address, Enum.map(allocations, & &1.sku))

            unless warehouse do
              {:error, :no_warehouse_available}
            else
              # 5. Generate pick list
              pick_list_items =
                Enum.map(allocations, fn alloc ->
                  %{sku: alloc.sku, quantity: alloc.quantity, bin_location: alloc.bin}
                end)

              {:ok, pick_list} =
                PickList.create(%{
                  warehouse_id: warehouse.id,
                  order_id:     order.id,
                  items:        pick_list_items,
                  priority:     order.priority,
                  created_at:   DateTime.utc_now()
                })

              # 6. Generate packing slip
              {:ok, _packing_slip} =
                PackingSlip.create(%{
                  order_id:     order.id,
                  warehouse_id: warehouse.id,
                  items:        order.line_items,
                  ship_to:      order.shipping_address,
                  gift_message: order.gift_message
                })

              # 7. Request shipping label from carrier
              carrier_request = %{
                origin:      warehouse.address,
                destination: order.shipping_address,
                packages:    order.package_dimensions,
                service:     order.shipping_service,
                reference:   order.number
              }

              case CarrierAPI.create_label(carrier_request) do
                {:error, reason} ->
                  Logger.error("Label creation failed for order #{order.id}: #{inspect(reason)}")
                  {:error, :label_creation_failed}

                {:ok, label} ->
                  Order.update_tracking(order.id, label.tracking_number, label.carrier)
                  Order.update_status(order.id, :in_fulfillment)

                  # 8. Notify customer
                  email_body = """
                  Hi #{order.customer_name},

                  Great news — your order ##{order.number} is being prepared for shipment!

                  Carrier:    #{label.carrier}
                  Tracking #: #{label.tracking_number}
                  Track at:   https://track.example.com/#{label.tracking_number}

                  Estimated delivery: #{label.estimated_delivery}
                  """

                  case Mailer.send_email(order.customer_email, "Your order is on its way!", email_body) do
                    {:ok, _}         -> :ok
                    {:error, reason} -> Logger.warning("Customer notification failed: #{inspect(reason)}")
                  end

                  Logger.info("Order #{order.id} dispatched — tracking #{label.tracking_number}")
                  {:ok, %{order: order, pick_list: pick_list, tracking: label.tracking_number}}
              end
            end
        end
    end
  end
end
```
