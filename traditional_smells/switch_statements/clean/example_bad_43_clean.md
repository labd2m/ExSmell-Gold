```elixir
defmodule FulfillmentRouter do
  @moduledoc """
  Routes outbound orders to fulfilment centres and calculates
  shipping costs based on delivery priority levels for an
  e-commerce order management system.
  """

  alias FulfillmentRouter.{Order, FulfilmentCentre, ShippingQuote, DispatchRecord}

  @type delivery_priority :: :economy | :standard | :express | :overnight

  @base_rate_per_kg 4.50

  @spec route_order(Order.t()) :: {:ok, DispatchRecord.t()} | {:error, term()}
  def route_order(%Order{} = order) do
    with {:ok, centre} <- select_centre(order),
         {:ok, quote} <- build_shipping_quote(order, centre) do
      record = %DispatchRecord{
        order_id: order.id,
        centre_id: centre.id,
        priority: order.delivery_priority,
        priority_label: priority_label(order.delivery_priority),
        estimated_cost: quote.total_cost,
        scheduled_at: quote.scheduled_at
      }

      {:ok, record}
    end
  end

  @spec build_shipping_quote(Order.t(), FulfilmentCentre.t()) ::
          {:ok, ShippingQuote.t()} | {:error, term()}
  defp build_shipping_quote(%Order{} = order, %FulfilmentCentre{} = centre) do
    base = order.total_weight_kg * @base_rate_per_kg
    multiplier = cost_multiplier(order.delivery_priority)
    total = Float.round(base * multiplier + centre.handling_fee, 2)
    scheduled = schedule_dispatch(order.delivery_priority)

    {:ok,
     %ShippingQuote{
       total_cost: total,
       scheduled_at: scheduled,
       priority: order.delivery_priority
     }}
  end

  @spec list_order_options(Order.t()) :: [map()]
  def list_order_options(%Order{} = order) do
    [:economy, :standard, :express, :overnight]
    |> Enum.map(fn priority ->
      order_with_priority = %{order | delivery_priority: priority}
      base = order.total_weight_kg * @base_rate_per_kg
      est_cost = Float.round(base * cost_multiplier(priority), 2)

      %{
        priority: priority,
        label: priority_label(priority),
        estimated_cost: est_cost
      }
    end)
  end

  @spec cost_multiplier(delivery_priority()) :: float()
  def cost_multiplier(priority) do
    case priority do
      :economy  -> 1.0
      :standard -> 1.5
      :express  -> 2.5
      :overnight -> 4.0
    end
  end

  @spec priority_label(delivery_priority()) :: String.t()
  def priority_label(priority) do
    case priority do
      :economy   -> "Economy (5–7 days)"
      :standard  -> "Standard (3–5 days)"
      :express   -> "Express (1–2 days)"
      :overnight -> "Overnight"
    end
  end

  @spec select_centre(Order.t()) :: {:ok, FulfilmentCentre.t()} | {:error, String.t()}
  defp select_centre(%Order{ship_to: address}) do
    FulfilmentCentre.nearest_to(address.lat, address.lng)
  end

  @spec schedule_dispatch(delivery_priority()) :: DateTime.t()
  defp schedule_dispatch(:overnight) do
    DateTime.utc_now() |> Map.put(:hour, 20) |> Map.put(:minute, 0)
  end

  defp schedule_dispatch(_priority) do
    next_business_day = Date.add(Date.utc_today(), 1)
    DateTime.new!(next_business_day, ~T[08:00:00])
  end
end
```
