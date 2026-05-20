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

end
```
