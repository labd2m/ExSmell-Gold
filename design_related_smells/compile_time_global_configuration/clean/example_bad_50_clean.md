```elixir
defmodule Logistics.ShippingRateCalculator do
  @moduledoc """
  Computes shipping rates for outbound orders.

  Rate calculation considers parcel weight, destination zone,
  order subtotal (for free-shipping eligibility), and a live
  carrier quote obtained via the configured carrier adapter.

  Monetary values are represented in cents (integer) throughout
  to avoid floating-point precision issues.
  """

  require Logger

  @base_rate_cents                 Application.fetch_env!(:logistics, :shipping_base_rate_cents)
  @free_shipping_threshold_cents   Application.fetch_env!(:logistics, :free_shipping_threshold_cents)
  @carrier_api_timeout_ms          Application.fetch_env!(:logistics, :carrier_api_timeout_ms)

  @carrier_adapter Application.compile_env(:logistics, :carrier_adapter, Logistics.Adapters.FedEx)

  @weight_rate_per_kg_cents 85
  @zone_surcharges %{
    domestic:       0,
    regional:     350,
    international: 1_200
  }

  @type parcel :: %{weight_kg: float(), zone: atom()}
  @type order  :: %{subtotal_cents: non_neg_integer(), items: [map()]}

  @type rate_result :: %{
    base_cents:      non_neg_integer(),
    surcharge_cents: non_neg_integer(),
    total_cents:     non_neg_integer(),
    free_shipping:   boolean(),
    carrier_quote:   map() | nil
  }

  @spec calculate_rate(order(), parcel()) :: {:ok, rate_result()} | {:error, String.t()}
  def calculate_rate(%{subtotal_cents: subtotal} = order, parcel) do
    Logger.debug("Calculating shipping rate",
      subtotal_cents: subtotal,
      weight_kg: parcel.weight_kg,
      zone: parcel.zone
    )

    if subtotal >= @free_shipping_threshold_cents do
      {:ok, free_shipping_result(order, parcel)}
    else
      compute_paid_rate(order, parcel)
    end
  end

  @spec estimate_delivery_days(atom()) :: {:ok, integer()} | {:error, :unknown_zone}
  def estimate_delivery_days(:domestic),       do: {:ok, 2}
  def estimate_delivery_days(:regional),       do: {:ok, 5}
  def estimate_delivery_days(:international),  do: {:ok, 14}
  def estimate_delivery_days(_),               do: {:error, :unknown_zone}

  defp compute_paid_rate(order, parcel) do
    with {:ok, base}     <- compute_base(parcel),
         {:ok, surcharge} <- zone_surcharge(parcel.zone),
         {:ok, quote}    <- fetch_carrier_quote(order, parcel) do
      total = base + surcharge

      result = %{
        base_cents:      base,
        surcharge_cents: surcharge,
        total_cents:     total,
        free_shipping:   false,
        carrier_quote:   quote
      }

      Logger.info("Rate computed",
        base_cents: base,
        surcharge_cents: surcharge,
        total_cents: total
      )

      {:ok, result}
    end
  end

  defp compute_base(%{weight_kg: kg}) when kg > 0 do
    weight_component = round(kg * @weight_rate_per_kg_cents)
    {:ok, @base_rate_cents + weight_component}
  end

  defp compute_base(_), do: {:error, "Invalid parcel weight"}

  defp zone_surcharge(zone) do
    case Map.fetch(@zone_surcharges, zone) do
      {:ok, surcharge} -> {:ok, surcharge}
      :error           -> {:error, "Unknown shipping zone: #{zone}"}
    end
  end

  defp fetch_carrier_quote(order, parcel) do
    task = Task.async(fn ->
      @carrier_adapter.get_rate(%{
        weight_kg:     parcel.weight_kg,
        zone:          parcel.zone,
        declared_value: order.subtotal_cents
      })
    end)

    case Task.yield(task, @carrier_api_timeout_ms) || Task.shutdown(task) do
      {:ok, {:ok, quote}}     -> {:ok, quote}
      {:ok, {:error, reason}} -> {:error, "Carrier API error: #{reason}"}
      nil                     ->
        Logger.warn("Carrier API timed out", timeout_ms: @carrier_api_timeout_ms)
        {:ok, nil}
    end
  end

  defp free_shipping_result(_order, parcel) do
    %{
      base_cents:      0,
      surcharge_cents: 0,
      total_cents:     0,
      free_shipping:   true,
      carrier_quote:   nil
    }
  end

  defp apply_discount(rate_cents, discount_pct) when discount_pct > 0 do
    discounted = round(rate_cents * (1 - discount_pct / 100))
    max(discounted, 0)
  end

  defp apply_discount(rate_cents, _), do: rate_cents
end
```
