# Annotated Example 03 — Complex Extractions in Clauses

## Metadata

| Field                  | Value                                                                                        |
|------------------------|----------------------------------------------------------------------------------------------|
| **Smell name**         | Complex extractions in clauses                                                               |
| **Expected location**  | `Logistics.ShipmentRouter.route/1`                                                           |
| **Affected function**  | `route/1`                                                                                    |
| **Short explanation**  | The function dispatches based on `priority` (clause selection) and `weight_kg` (guard), but also eagerly extracts `shipment_id`, `origin`, `destination`, `carrier_code`, and `declared_value` in every clause head — none of which influence which clause fires. With four clauses, each carrying six extractions, the reader must laboriously scan every binding to understand the dispatch logic. |

---

```elixir
defmodule Logistics.ShipmentRouter do
  @moduledoc """
  Determines the routing strategy for outbound shipments based on
  priority tier and physical characteristics. Integrates with carrier
  APIs and the internal warehouse management system.
  """

  require Logger

  alias Logistics.{CarrierGateway, WarehouseQueue, AuditTrail, RateCalculator}

  @express_weight_limit_kg 30.0
  @freight_weight_threshold_kg 70.0

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `shipment_id`, `origin`, `destination`,
  # `carrier_code`, and `declared_value` are extracted in every clause head but
  # are only ever used inside the function bodies. The actual clause selection
  # depends solely on `priority`, while `weight_kg` is used in the guards. The
  # mixture of dispatch-critical extractions and body-only extractions in the
  # same destructure pattern makes it genuinely difficult to understand the
  # routing logic at a glance, especially across four clauses.
  def route(%Logistics.Shipment{
        shipment_id: shipment_id,
        origin: origin,
        destination: destination,
        carrier_code: carrier_code,
        declared_value: declared_value,
        priority: :express,
        weight_kg: weight_kg
      })
      when weight_kg <= @express_weight_limit_kg do
    Logger.info("[ShipmentRouter] Routing express shipment #{shipment_id} via #{carrier_code}")

    rate = RateCalculator.express_rate(origin, destination, weight_kg)

    with {:ok, booking_ref} <- CarrierGateway.book_express(carrier_code, shipment_id, rate),
         :ok <- WarehouseQueue.prioritize(shipment_id),
         :ok <- AuditTrail.log(:routed_express, shipment_id, %{
                  carrier: carrier_code,
                  rate: rate,
                  declared_value: declared_value
                }) do
      Logger.info("[ShipmentRouter] Express booking confirmed: #{booking_ref}")
      {:ok, :express, booking_ref}
    else
      {:error, reason} ->
        Logger.error("[ShipmentRouter] Express routing failed for #{shipment_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def route(%Logistics.Shipment{
        shipment_id: shipment_id,
        origin: origin,
        destination: destination,
        carrier_code: carrier_code,
        declared_value: declared_value,
        priority: :express,
        weight_kg: weight_kg
      })
      when weight_kg > @express_weight_limit_kg do
    Logger.warning(
      "[ShipmentRouter] Express shipment #{shipment_id} exceeds weight limit " <>
        "(#{weight_kg} kg). Downgrading to standard freight."
    )

    rate = RateCalculator.standard_rate(origin, destination, weight_kg)

    with {:ok, booking_ref} <- CarrierGateway.book_standard(carrier_code, shipment_id, rate),
         :ok <- AuditTrail.log(:downgraded_to_standard, shipment_id, %{
                  original_priority: :express,
                  weight_kg: weight_kg,
                  declared_value: declared_value
                }) do
      {:ok, :standard_downgrade, booking_ref}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  def route(%Logistics.Shipment{
        shipment_id: shipment_id,
        origin: origin,
        destination: destination,
        carrier_code: carrier_code,
        declared_value: declared_value,
        priority: :standard,
        weight_kg: weight_kg
      })
      when weight_kg <= @freight_weight_threshold_kg do
    Logger.info("[ShipmentRouter] Routing standard shipment #{shipment_id}")

    rate = RateCalculator.standard_rate(origin, destination, weight_kg)
    estimated_transit = RateCalculator.estimate_transit_days(origin, destination, :standard)

    with {:ok, booking_ref} <- CarrierGateway.book_standard(carrier_code, shipment_id, rate),
         :ok <- WarehouseQueue.enqueue(shipment_id, :standard),
         :ok <- AuditTrail.log(:routed_standard, shipment_id, %{
                  rate: rate,
                  transit_days: estimated_transit,
                  declared_value: declared_value
                }) do
      {:ok, :standard, booking_ref}
    else
      {:error, reason} ->
        Logger.error("[ShipmentRouter] Standard routing failed for #{shipment_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def route(%Logistics.Shipment{
        shipment_id: shipment_id,
        origin: origin,
        destination: destination,
        carrier_code: carrier_code,
        declared_value: declared_value,
        priority: :standard,
        weight_kg: weight_kg
      })
      when weight_kg > @freight_weight_threshold_kg do
    Logger.info("[ShipmentRouter] Routing heavy freight shipment #{shipment_id} (#{weight_kg} kg)")

    rate = RateCalculator.freight_rate(origin, destination, weight_kg)
    requires_inspection = declared_value > 10_000

    with {:ok, booking_ref} <- CarrierGateway.book_freight(carrier_code, shipment_id, rate),
         :ok <- maybe_schedule_inspection(shipment_id, requires_inspection),
         :ok <- AuditTrail.log(:routed_freight, shipment_id, %{
                  rate: rate,
                  weight_kg: weight_kg,
                  inspection_required: requires_inspection
                }) do
      {:ok, :freight, booking_ref}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end
  # VALIDATION: SMELL END

  def route(%Logistics.Shipment{shipment_id: shipment_id, priority: unknown}) do
    Logger.error("[ShipmentRouter] Unknown priority '#{unknown}' for shipment #{shipment_id}")
    {:error, :unknown_priority}
  end

  # --- Private helpers ---

  defp maybe_schedule_inspection(_shipment_id, false), do: :ok

  defp maybe_schedule_inspection(shipment_id, true) do
    Logistics.InspectionQueue.schedule(shipment_id)
  end
end
```
