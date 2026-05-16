```elixir
defmodule Logistics.ShipmentDispatcher do
  @moduledoc """
  Coordinates the dispatch lifecycle for outbound shipments:
  order resolution, carrier selection, label generation, and
  warehouse instruction issuance.
  """

  alias Logistics.{OrderRepo, CarrierGateway, LabelService, WarehouseAPI}
  require Logger

  @doc """
  Dispatches a shipment for `order_id` using the given `options`.

  Options:
    - `:priority` — `:standard` | `:express` | `:overnight`
    - `:warehouse_id` — originating warehouse identifier

  Returns `{:ok, shipment}` or a domain-specific error.
  """
  @spec dispatch_shipment(String.t(), keyword()) ::
          {:ok, map()}
          | {:error, :order_not_dispatchable}
          | {:error, :no_carrier_available}
          | {:error, :label_generation_failed}
          | {:error, :warehouse_rejected}
  def dispatch_shipment(order_id, opts \\ []) do
    priority     = Keyword.get(opts, :priority, :standard)
    warehouse_id = Keyword.fetch!(opts, :warehouse_id)

    with {:ok, order}    <- OrderRepo.fetch_dispatchable(order_id),
         {:ok, carrier}  <- CarrierGateway.select(order, priority),
         {:ok, label}    <- LabelService.generate(order, carrier),
         :ok             <- WarehouseAPI.issue_pick_instruction(warehouse_id, order, label) do
      shipment = build_shipment_record(order, carrier, label)
      Logger.info("Dispatched shipment #{shipment.tracking_number} via #{carrier.code}")
      {:ok, shipment}
    else
      {:error, reason} when reason in [:not_found, :already_dispatched, :cancelled] ->
        Logger.warn("Order #{order_id} not dispatchable: #{reason}")
        {:error, :order_not_dispatchable}

      {:error, :no_carrier, constraints} ->
        Logger.warn("No carrier matched constraints: #{inspect(constraints)}")
        {:error, :no_carrier_available}

      {:error, :label, detail} ->
        Logger.error("Label generation error: #{inspect(detail)}")
        {:error, :label_generation_failed}

      {:error, :rejected, code} ->
        Logger.error("Warehouse #{warehouse_id} rejected instruction, code=#{code}")
        {:error, :warehouse_rejected}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_shipment_record(order, carrier, label) do
    %{
      id:              Ecto.UUID.generate(),
      order_id:        order.id,
      carrier_code:    carrier.code,
      tracking_number: label.tracking_number,
      label_url:       label.url,
      dispatched_at:   DateTime.utc_now(),
      status:          :in_transit
    }
  end
end
```
