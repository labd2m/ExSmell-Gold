```elixir
defmodule Logistics.ShipmentHandler do
  @moduledoc """
  Orchestrates the full lifecycle of a new outbound shipment from order confirmation
  through carrier label generation and warehouse dispatch.
  """

  alias Logistics.{Shipment, Carrier, WarehouseTask, Repo, EventBus}
  alias Orders.Order
  require Logger

  @supported_carriers [:fedex, :ups, :dhl, :usps]
  @max_weight_kg 70.0

  def process(%Order{} = order) do
    Logger.info("Processing shipment for order #{order.id}")

    # --- Basic validation ---
    cond do
      is_nil(order.shipping_address) ->
        {:error, :missing_shipping_address}

      Enum.empty?(order.items) ->
        {:error, :empty_order}

      true ->
        # --- Compute total weight ---
        total_weight_kg =
          Enum.reduce(order.items, 0.0, fn item, acc ->
            acc + item.weight_kg * item.quantity
          end)

        if total_weight_kg > @max_weight_kg do
          Logger.warning("Order #{order.id} exceeds max weight: #{total_weight_kg}kg")
          {:error, {:weight_exceeded, total_weight_kg}}
        else
          # --- Select carrier ---
          country = order.shipping_address.country

          preferred_carrier =
            cond do
              country == "US" and total_weight_kg < 0.5 -> :usps
              country == "US"                           -> :fedex
              country in ["DE", "FR", "IT", "ES"]      -> :dhl
              true                                      -> :ups
            end

          unless preferred_carrier in @supported_carriers do
            {:error, {:unsupported_carrier, preferred_carrier}}
          else
            # --- Request label from carrier ---
            label_payload = %{
              sender: Application.get_env(:logistics, :warehouse_address),
              recipient: order.shipping_address,
              weight_kg: total_weight_kg,
              reference: "ORD-#{order.id}"
            }

            case Carrier.request_label(preferred_carrier, label_payload) do
              {:ok, %{tracking_number: tracking, label_url: label_url}} ->
                # --- Create shipment record ---
                shipment_attrs = %{
                  order_id: order.id,
                  carrier: preferred_carrier,
                  tracking_number: tracking,
                  label_url: label_url,
                  weight_kg: total_weight_kg,
                  status: :pending_pickup,
                  estimated_delivery: Date.add(Date.utc_today(), 5)
                }

                {:ok, shipment} = Repo.insert(Shipment.changeset(%Shipment{}, shipment_attrs))

                # --- Create warehouse task ---
                task_attrs = %{
                  shipment_id: shipment.id,
                  type: :pack_and_dispatch,
                  priority: (if total_weight_kg > 10.0, do: :high, else: :normal),
                  due_at: DateTime.add(DateTime.utc_now(), 4 * 3600, :second)
                }

                {:ok, _task} = Repo.insert(WarehouseTask.changeset(%WarehouseTask{}, task_attrs))

                # --- Update order status ---
                order
                |> Order.changeset(%{status: :awaiting_shipment})
                |> Repo.update()

                # --- Publish event ---
                EventBus.publish("shipment.created", %{
                  order_id: order.id,
                  shipment_id: shipment.id,
                  tracking_number: tracking,
                  carrier: preferred_carrier
                })

                Logger.info("Shipment #{shipment.id} created for order #{order.id} via #{preferred_carrier}")
                {:ok, shipment}

              {:error, reason} ->
                Logger.error("Label request failed for order #{order.id}: #{inspect(reason)}")
                {:error, {:label_request_failed, reason}}
            end
          end
        end
    end
  end

  def cancel(%Shipment{status: :pending_pickup} = shipment) do
    shipment
    |> Shipment.changeset(%{status: :cancelled})
    |> Repo.update()
  end

  def cancel(%Shipment{}), do: {:error, :cannot_cancel_dispatched_shipment}
end
```
