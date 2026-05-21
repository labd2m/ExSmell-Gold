# Code Smell Example — Annotated

## Metadata

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `Orders.OrderValidator.validate/1`
- **Affected function(s):** `Orders.OrderValidator.validate/1` (library side); `Orders.PlacementService.place/1` (client side)
- **Explanation:** `validate/1` raises `RuntimeError` for typical business rule violations in an order: empty cart, minimum order value not met, and an unrecognised shipping region. These are expected input conditions, not system errors. The placement service cannot inspect a structured result — it must catch exceptions — which is the only mechanism available for control-flow.

```elixir
defmodule Orders.LineItem do
  @moduledoc "A single product line in a customer order."

  @enforce_keys [:sku_id, :quantity, :unit_price]
  defstruct [:sku_id, :quantity, :unit_price, :discount, :metadata]

  def subtotal(%__MODULE__{quantity: q, unit_price: p, discount: d}) do
    raw = q * p
    raw - (d || 0)
  end
end

defmodule Orders.Address do
  @moduledoc "Shipping or billing address."

  @enforce_keys [:line1, :city, :country_code, :postal_code]
  defstruct [:line1, :line2, :city, :state, :country_code, :postal_code]
end

defmodule Orders.Order do
  @moduledoc "An incoming customer order before persistence."

  @enforce_keys [:id, :customer_id, :line_items, :shipping_address]
  defstruct [
    :id,
    :customer_id,
    :line_items,
    :shipping_address,
    :coupon_code,
    :placed_at,
    :status
  ]

  def total(%__MODULE__{line_items: items}) do
    Enum.reduce(items, 0.0, fn item, acc -> acc + Orders.LineItem.subtotal(item) end)
  end
end

defmodule Orders.RegionConfig do
  @moduledoc "Shipping region policies."

  @supported_regions ~w[US CA GB DE FR AU BR]

  def supported?(code), do: code in @supported_regions
  def all, do: @supported_regions
  def minimum_order_value("BR"), do: 30.0
  def minimum_order_value(_), do: 10.0
end

defmodule Orders.OrderValidator do
  @moduledoc """
  Validates an order against business rules before it is persisted and
  routed to the fulfilment pipeline.
  """

  alias Orders.{Order, RegionConfig}
  require Logger

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because `validate/1` raises RuntimeError for three
  # VALIDATION: standard order-validation outcomes: empty cart, order below minimum
  # VALIDATION: value, and unsupported shipping region. These are expected domain
  # VALIDATION: constraints that the placement service should be able to handle as
  # VALIDATION: data. The only way to intercept them is a try/rescue block, meaning
  # VALIDATION: the client is forced to use exceptions for control-flow.
  def validate(%Order{} = order) do
    if Enum.empty?(order.line_items) do
      raise RuntimeError, message: "Order '#{order.id}' has no line items"
    end

    country = order.shipping_address.country_code

    unless RegionConfig.supported?(country) do
      raise RuntimeError,
        message:
          "Shipping to '#{country}' is not supported. " <>
            "Supported regions: #{Enum.join(RegionConfig.all(), ", ")}"
    end

    total = Order.total(order)
    min_value = RegionConfig.minimum_order_value(country)

    if total < min_value do
      raise RuntimeError,
        message:
          "Order total #{Float.round(total, 2)} is below the minimum of #{min_value} for #{country}"
    end

    Logger.debug("Order #{order.id} passed validation (total=#{total}, region=#{country})")
    :ok
  end
  # VALIDATION: SMELL END
end

defmodule Orders.PlacementService do
  @moduledoc """
  Accepts an incoming order, validates it, and persists it to the order ledger.
  Returns a structured result describing the outcome.
  """

  alias Orders.{Order, OrderValidator}
  require Logger

  defmodule OrderRecord do
    @enforce_keys [:id, :customer_id, :total, :status, :placed_at]
    defstruct [:id, :customer_id, :total, :status, :placed_at, :line_item_count]
  end

  def place(%Order{} = order) do
    # Client is forced to use try/rescue because OrderValidator.validate/1
    # raises RuntimeError on validation failures instead of returning {:error, reason}.
    try do
      :ok = OrderValidator.validate(order)

      record = %OrderRecord{
        id: order.id,
        customer_id: order.customer_id,
        total: Order.total(order),
        status: :pending,
        placed_at: DateTime.utc_now(),
        line_item_count: length(order.line_items)
      }

      Logger.info("Order #{order.id} placed for customer=#{order.customer_id}")
      {:ok, record}
    rescue
      e in RuntimeError ->
        Logger.warning("Order #{order.id} rejected: #{e.message}")
        {:error, e.message}
    end
  end

  def place_many(orders) when is_list(orders) do
    Enum.reduce(orders, %{placed: [], rejected: []}, fn order, acc ->
      case place(order) do
        {:ok, record} ->
          Map.update!(acc, :placed, &[record | &1])

        {:error, reason} ->
          Map.update!(acc, :rejected, &[%{order_id: order.id, reason: reason} | &1])
      end
    end)
  end
end
```
