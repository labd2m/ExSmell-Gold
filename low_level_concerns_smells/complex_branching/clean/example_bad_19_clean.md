```elixir
defmodule Logistics.FreightQuoteResolver do
  @moduledoc """
  Requests freight quotes from carrier APIs and stores the results,
  handling all carrier response types and enforcing routing policy rules.
  """

  alias Logistics.FreightCarrierClient
  alias Logistics.QuoteStore
  alias Logistics.RestrictionRegistry
  alias Logistics.CapacityTracker
  alias Logistics.RouteBlacklist
  alias Logistics.AuditLogger

  @quote_ttl_seconds 1_800
  @indicative_surcharge_pct 0.15

  def fetch_quote(shipment_id, carrier_id, shipment, operator_id) do
    with {:ok, quote_request} <- build_quote_request(shipment),
         {:ok, result} <- resolve_quote_response(quote_request, carrier_id, operator_id),
         :ok <- QuoteStore.persist(shipment_id, carrier_id, result) do
      {:ok, result}
    end
  end

  defp resolve_quote_response(quote_request, carrier_id, operator_id) do
    case FreightCarrierClient.request_quote(carrier_id, quote_request) do
      {:ok, %{status: "quoted", quote_id: qid, price_cents: price, transit_days: days, valid_until: vu}} ->
        AuditLogger.log(:quote_received, carrier_id, %{quote_id: qid, price: price, days: days})
        {:ok, %{status: :quoted, quote_id: qid, price_cents: price, transit_days: days, valid_until: vu}}

      {:ok, %{status: "indicative", estimate_cents: est, caveat: caveat}} ->
        adjusted = round(est * (1 + @indicative_surcharge_pct))
        AuditLogger.log(:indicative_quote, carrier_id, %{estimate: est, adjusted: adjusted})
        {:ok, %{status: :indicative, estimate_cents: adjusted, caveat: caveat, valid_until: nil}}

      {:ok, %{status: "rejected", reason: "origin_not_serviceable", origin_code: oc}} ->
        RouteBlacklist.add_origin(carrier_id, oc)
        AuditLogger.log(:origin_not_serviceable, carrier_id, %{origin: oc})
        {:error, {:origin_not_serviceable, oc}}

      {:ok, %{status: "rejected", reason: "destination_not_serviceable", destination_code: dc}} ->
        RouteBlacklist.add_destination(carrier_id, dc)
        AuditLogger.log(:destination_not_serviceable, carrier_id, %{destination: dc})
        {:error, {:destination_not_serviceable, dc}}

      {:ok, %{status: "rejected", reason: "weight_exceeded", max_kg: max, requested_kg: req}} ->
        AuditLogger.log(:weight_limit_exceeded, carrier_id, %{max: max, requested: req})
        {:error, {:weight_exceeded, %{max_kg: max, requested_kg: req}}}

      {:ok, %{status: "rejected", reason: "hazmat_restriction", hazmat_class: hc, regulation: reg}} ->
        RestrictionRegistry.record(carrier_id, :hazmat, %{class: hc, regulation: reg})
        AuditLogger.log(:hazmat_restriction, carrier_id, %{class: hc, regulation: reg})
        {:error, {:hazmat_restriction, hc}}

      {:ok, %{status: "rejected", reason: "insurance_required", min_coverage_cents: min}} ->
        AuditLogger.log(:insurance_required, carrier_id, %{min_coverage: min, operator: operator_id})
        {:error, {:insurance_required, min}}

      {:ok, %{status: "rejected", reason: "capacity_full", available_from: af}} ->
        CapacityTracker.record_saturation(carrier_id, af)
        AuditLogger.log(:carrier_capacity_full, carrier_id, %{available_from: af})
        {:error, {:capacity_full, af}}

      {:ok, %{status: "rejected", reason: "quote_expired", expired_at: exp}} ->
        AuditLogger.log(:quote_expired_race, carrier_id, %{expired_at: exp, operator: operator_id})
        {:error, {:quote_expired, exp}}

      {:ok, %{status: "rejected", reason: other}} ->
        AuditLogger.log(:quote_unknown_rejection, carrier_id, %{reason: other})
        {:error, {:quote_rejected, other}}

      {:error, %{reason: :timeout}} ->
        AuditLogger.log(:carrier_api_timeout, carrier_id, %{operator: operator_id})
        {:error, :carrier_api_timeout}

      {:error, reason} ->
        AuditLogger.log(:carrier_api_error, carrier_id, %{reason: reason})
        {:error, :carrier_api_error}
    end
  end

  defp build_quote_request(shipment) do
    {:ok,
     %{
       origin_code: shipment.origin_code,
       destination_code: shipment.destination_code,
       weight_kg: shipment.weight_kg,
       volume_m3: shipment.volume_m3,
       hazmat: shipment.hazmat,
       insured_value_cents: shipment.insured_value_cents,
       requested_at: DateTime.utc_now(),
       ttl_seconds: @quote_ttl_seconds
     }}
  end
end
```
