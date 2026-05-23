```elixir
defmodule Logistics.ShipmentService do
  @moduledoc """
  Handles shipment dispatch including carrier selection,
  label generation, inventory deduction, and tracking setup.
  """

  require Logger

  alias Logistics.{
    Shipment, Address, Carrier, Label,
    Inventory, TrackingEvent, Mailer
  }

  @max_weight_kg      70.0
  @max_dimension_cm   270
  @default_carrier    :fedex

  def dispatch(%Shipment{} = shipment, opts \\ []) do
    dry_run  = Keyword.get(opts, :dry_run, false)
    priority = Keyword.get(opts, :priority, :standard)

    # 1. Validate origin and destination addresses
    with :ok <- Address.validate(shipment.origin),
         :ok <- Address.validate(shipment.destination) do

      # 2. Check physical constraints
      total_weight = Enum.sum(Enum.map(shipment.packages, & &1.weight_kg))

      oversized =
        Enum.any?(shipment.packages, fn pkg ->
          girth = 2 * (pkg.width_cm + pkg.height_cm)
          pkg.length_cm + girth > @max_dimension_cm
        end)

      cond do
        total_weight > @max_weight_kg ->
          {:error, {:weight_exceeded, total_weight}}

        oversized ->
          {:error, :oversized_package}

        true ->
          # 3. Select carrier based on destination and priority
          carrier =
            cond do
              priority == :overnight ->
                Carrier.find_fastest(shipment.destination)

              shipment.destination.country != "US" ->
                Carrier.find_international(shipment.destination.country)

              total_weight > 30.0 ->
                Carrier.find_by_capability(:heavy_freight)

              true ->
                @default_carrier
            end

          case Carrier.get_rate(carrier, shipment) do
            {:error, reason} ->
              {:error, {:carrier_rate_failed, reason}}

            {:ok, rate_info} ->
              # 4. Generate shipping label
              label_params = %{
                carrier:       carrier,
                origin:        shipment.origin,
                destination:   shipment.destination,
                packages:      shipment.packages,
                service_level: priority,
                reference:     shipment.reference_number
              }

              case Label.generate(label_params) do
                {:error, reason} ->
                  {:error, {:label_generation_failed, reason}}

                {:ok, label} ->
                  unless dry_run do
                    # 5. Deduct inventory for each package item
                    deduction_errors =
                      shipment.packages
                      |> Enum.flat_map(& &1.items)
                      |> Enum.reduce([], fn item, errs ->
                        case Inventory.deduct(item.sku, item.quantity) do
                          :ok              -> errs
                          {:error, reason} -> [{item.sku, reason} | errs]
                        end
                      end)

                    if deduction_errors != [] do
                      Logger.error("Inventory deduction failed: #{inspect(deduction_errors)}")
                      {:error, {:inventory_deduction_failed, deduction_errors}}
                    else
                      # 6. Create initial tracking event
                      tracking = %TrackingEvent{
                        shipment_id:  shipment.id,
                        carrier:      to_string(carrier),
                        tracking_no:  label.tracking_number,
                        status:       "dispatched",
                        location:     shipment.origin.city,
                        occurred_at:  DateTime.utc_now()
                      }

                      case TrackingEvent.insert(tracking) do
                        {:error, r} ->
                          Logger.warning("Tracking event insert failed: #{inspect(r)}")
                        _ -> :ok
                      end

                      # 7. Notify the recipient
                      email_body = """
                      Hi #{shipment.recipient_name},

                      Your shipment ##{shipment.reference_number} has been dispatched.
                      Carrier:    #{carrier}
                      Tracking #: #{label.tracking_number}
                      Est. arrival: #{rate_info.estimated_delivery}

                      Track your parcel at https://track.example.com/#{label.tracking_number}
                      """

                      case Mailer.send_email(shipment.recipient_email,
                                             "Your shipment is on its way!", email_body) do
                        {:ok, _}         -> Logger.info("Dispatch email sent to #{shipment.recipient_email}")
                        {:error, reason} -> Logger.warning("Failed to send dispatch email: #{inspect(reason)}")
                      end

                      {:ok, %{shipment: shipment, label: label, rate: rate_info}}
                    end
                  else
                    {:ok, %{dry_run: true, estimated_rate: rate_info, carrier: carrier}}
                  end
              end
          end
      end
    end
  end
end
```
