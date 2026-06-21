# Annotated Bad Example 44

## Metadata

- **Smell name**: Complex extractions in clauses
- **Expected smell location**: `Logistics.ShipmentRouter.route_shipment/1` — all three clauses
- **Affected function(s)**: `route_shipment/1`
- **Explanation**: Each clause of `route_shipment/1` binds `weight` and `destination_zone` in the signature to serve the guard, but also binds `carrier`, `tracking_id`, `sender_id`, `declared_value`, and `fragile` there even though those fields are only ever referenced inside the clause body. Repeating this mixed-intent destructuring across all routing clauses obscures the dispatch logic and makes each clause header harder to read than necessary.

## Code

```elixir
defmodule Logistics.ShipmentRouter do
  @moduledoc """
  Determines carrier routing, SLA class, and compliance requirements
  for outbound shipments based on weight, destination, and content flags.
  """

  alias Logistics.{Shipment, CarrierAPI, ComplianceChecker, AuditLog, Mailer}

  @domestic_weight_limit_kg 30.0
  @express_weight_limit_kg 10.0
  @high_value_threshold 2_000.0

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `weight` and `destination_zone` are
  # required for the guard conditions, but `carrier`, `tracking_id`, `sender_id`,
  # `declared_value`, and `fragile` are also pulled out in every clause
  # signature despite being used only inside the body. The reader cannot tell
  # which bindings influence clause selection without inspecting the body.

  def route_shipment(%Shipment{
        weight: weight,
        destination_zone: destination_zone,
        carrier: carrier,
        tracking_id: tracking_id,
        sender_id: sender_id,
        declared_value: declared_value,
        fragile: fragile
      })
      when destination_zone == :domestic and weight <= @express_weight_limit_kg do
    sla_class = if fragile, do: :express_fragile, else: :express

    compliance_result =
      ComplianceChecker.check(:domestic, declared_value, fragile)

    case compliance_result do
      :ok ->
        {:ok, rate} = CarrierAPI.get_rate(carrier, :domestic_express, weight)

        AuditLog.write(:shipment_routed, %{
          tracking_id: tracking_id,
          sender_id: sender_id,
          carrier: carrier,
          sla_class: sla_class,
          rate: rate,
          declared_value: declared_value
        })

        {:ok, %{tracking_id: tracking_id, sla_class: sla_class, rate: rate, carrier: carrier}}

      {:error, reason} ->
        AuditLog.write(:shipment_compliance_failed, %{
          tracking_id: tracking_id,
          sender_id: sender_id,
          reason: reason
        })
        {:error, {:compliance_failure, tracking_id, reason}}
    end
  end

  def route_shipment(%Shipment{
        weight: weight,
        destination_zone: destination_zone,
        carrier: carrier,
        tracking_id: tracking_id,
        sender_id: sender_id,
        declared_value: declared_value,
        fragile: fragile
      })
      when destination_zone == :domestic and weight > @express_weight_limit_kg and
             weight <= @domestic_weight_limit_kg do
    sla_class = if fragile, do: :standard_fragile, else: :standard
    compliance_result = ComplianceChecker.check(:domestic, declared_value, fragile)

    case compliance_result do
      :ok ->
        {:ok, rate} = CarrierAPI.get_rate(carrier, :domestic_standard, weight)

        extra_handling = if declared_value > @high_value_threshold, do: 25.0, else: 0.0

        AuditLog.write(:shipment_routed, %{
          tracking_id: tracking_id,
          sender_id: sender_id,
          carrier: carrier,
          sla_class: sla_class,
          rate: rate + extra_handling,
          declared_value: declared_value
        })

        {:ok,
         %{
           tracking_id: tracking_id,
           sla_class: sla_class,
           rate: rate + extra_handling,
           carrier: carrier
         }}

      {:error, reason} ->
        AuditLog.write(:shipment_compliance_failed, %{
          tracking_id: tracking_id,
          sender_id: sender_id,
          reason: reason
        })
        {:error, {:compliance_failure, tracking_id, reason}}
    end
  end

  def route_shipment(%Shipment{
        weight: weight,
        destination_zone: destination_zone,
        carrier: carrier,
        tracking_id: tracking_id,
        sender_id: sender_id,
        declared_value: declared_value,
        fragile: fragile
      })
      when destination_zone == :international do
    compliance_result =
      ComplianceChecker.check(:international, declared_value, fragile)

    case compliance_result do
      :ok ->
        {:ok, rate} = CarrierAPI.get_rate(carrier, :international, weight)
        customs_fee = ComplianceChecker.customs_fee(declared_value, destination_zone)

        AuditLog.write(:shipment_routed_international, %{
          tracking_id: tracking_id,
          sender_id: sender_id,
          carrier: carrier,
          rate: rate,
          customs_fee: customs_fee,
          declared_value: declared_value,
          weight: weight,
          fragile: fragile
        })

        Mailer.send_customs_notice(sender_id, tracking_id, customs_fee)

        {:ok,
         %{
           tracking_id: tracking_id,
           sla_class: :international,
           rate: rate,
           customs_fee: customs_fee,
           carrier: carrier
         }}

      {:error, reason} ->
        {:error, {:compliance_failure, tracking_id, reason}}
    end
  end

  # VALIDATION: SMELL END
end
```
