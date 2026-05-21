```elixir
defmodule Commerce.OrderSummarizer do
  use GenServer

  @moduledoc """
  Builds display-ready order summary structures for confirmation emails,
  the customer portal, and the internal operations dashboard.
  """

  @status_labels %{
    "pending_payment" => "Awaiting Payment",
    "payment_received" => "Payment Confirmed",
    "processing" => "Being Processed",
    "awaiting_fulfillment" => "Ready to Ship",
    "shipped" => "Shipped",
    "in_transit" => "In Transit",
    "out_for_delivery" => "Out for Delivery",
    "delivered" => "Delivered",
    "cancelled" => "Cancelled",
    "refunded" => "Refunded",
    "on_hold" => "On Hold"
  }

  @fulfillment_days %{
    "standard" => 5,
    "express" => 2,
    "overnight" => 1,
    "economy" => 10
  }



  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Builds a complete display summary map for an order.
  """
  def build(pid, order) do
    GenServer.call(pid, {:build, order})
  end

  @doc """
  Returns a formatted list of line items for display.
  """
  def line_items_display(pid, order) do
    GenServer.call(pid, {:line_items_display, order})
  end

  @doc """
  Returns a human-readable status label for an order status code.
  """
  def status_label(pid, status_code) do
    GenServer.call(pid, {:status_label, status_code})
  end

  @doc """
  Returns the estimated delivery date as a `Date`.
  """
  def fulfillment_eta(pid, order) do
    GenServer.call(pid, {:fulfillment_eta, order})
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:build, order}, _from, state) do
    label = Map.get(@status_labels, order.status, order.status)
    eta = compute_eta(order)

    summary = %{
      order_number: order.id,
      placed_at: order.inserted_at,
      status: order.status,
      status_label: label,
      line_items: format_line_items(order.line_items),
      subtotal: compute_subtotal(order.line_items),
      shipping_cost: Map.get(order, :shipping_cost, 0.0),
      discount: Map.get(order, :discount, 0.0),
      tax: Map.get(order, :tax, 0.0),
      grand_total: order.total,
      shipping_address: format_address(order.shipping_address),
      shipping_method: Map.get(order, :shipping_method, "standard"),
      estimated_delivery: eta,
      can_cancel: order.status in ["pending_payment", "payment_received"]
    }

    {:reply, {:ok, summary}, state}
  end

  @impl true
  def handle_call({:line_items_display, order}, _from, state) do
    items = format_line_items(order.line_items)
    {:reply, {:ok, items}, state}
  end

  @impl true
  def handle_call({:status_label, status_code}, _from, state) do
    label = Map.get(@status_labels, status_code, status_code)
    {:reply, {:ok, label}, state}
  end

  @impl true
  def handle_call({:fulfillment_eta, order}, _from, state) do
    {:reply, {:ok, compute_eta(order)}, state}
  end

  defp format_line_items(line_items) do
    Enum.map(line_items, fn item ->
      %{
        sku: item.sku,
        name: item.product_name,
        quantity: item.quantity,
        unit_price: item.unit_price,
        line_total: Float.round(item.quantity * item.unit_price, 2)
      }
    end)
  end

  defp compute_subtotal(line_items) do
    line_items
    |> Enum.map(&(&1.quantity * &1.unit_price))
    |> Enum.sum()
    |> Float.round(2)
  end

  defp compute_eta(order) do
    days = Map.get(@fulfillment_days, Map.get(order, :shipping_method, "standard"), 5)
    Date.add(Date.utc_today(), days)
  end

  defp format_address(addr) when is_map(addr) do
    "#{addr.street}, #{addr.city}, #{addr.state} #{addr.zip}"
  end

  defp format_address(nil), do: nil
end
```
