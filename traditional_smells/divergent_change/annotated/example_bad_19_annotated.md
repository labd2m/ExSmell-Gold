# Annotated Example — Divergent Change

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** `OrderManager` module (entire module)
- **Affected functions:** `create_order/2`, `apply_discount/2`, `calculate_tax/2`, `ship_order/2`, `generate_invoice/2`, `send_confirmation/2`
- **Short explanation:** The `OrderManager` module bundles three completely unrelated responsibilities — order lifecycle management, shipping logistics, and invoice generation — meaning it must change for entirely different business reasons (e.g., a new carrier integration, a new tax rule, or an invoicing format change).

---

```elixir
defmodule Commerce.OrderManager do
  @moduledoc """
  Handles order creation, shipping, and invoicing for the Commerce platform.
  """

  require Logger

  alias Commerce.Repo
  alias Commerce.Orders.Order
  alias Commerce.Customers.Customer
  alias Commerce.Products.Product

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module bundles at least three
  # unrelated responsibilities: (1) order lifecycle, (2) shipping/logistics,
  # and (3) invoice generation. Each group will evolve independently and
  # force unrelated changes into this single module.

  ## ──────────────────────────────────────────
  ## Reason to modify (1): Order business rules
  ## ──────────────────────────────────────────

  @doc "Creates a new order for a customer."
  def create_order(%Customer{} = customer, items) when is_list(items) do
    total = Enum.reduce(items, Decimal.new(0), fn item, acc ->
      line = Decimal.mult(item.unit_price, item.quantity)
      Decimal.add(acc, line)
    end)

    changeset =
      Order.changeset(%Order{}, %{
        customer_id: customer.id,
        items: items,
        subtotal: total,
        status: :pending
      })

    case Repo.insert(changeset) do
      {:ok, order} ->
        Logger.info("Order #{order.id} created for customer #{customer.id}")
        {:ok, order}

      {:error, changeset} ->
        Logger.warning("Failed to create order: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  @doc "Applies a promotional discount code to an existing order."
  def apply_discount(%Order{status: :pending} = order, discount_code) do
    discount_rate = fetch_discount_rate(discount_code)

    discounted =
      order.subtotal
      |> Decimal.mult(Decimal.sub(Decimal.new(1), discount_rate))

    order
    |> Order.changeset(%{discount_code: discount_code, subtotal: discounted})
    |> Repo.update()
  end

  def apply_discount(%Order{}, _code), do: {:error, :order_not_editable}

  @doc "Calculates applicable taxes based on the customer's region."
  def calculate_tax(%Order{} = order, region) do
    rate = tax_rate_for_region(region)
    tax_amount = Decimal.mult(order.subtotal, rate)

    order
    |> Order.changeset(%{tax_amount: tax_amount})
    |> Repo.update()
  end

  ## ──────────────────────────────────────────
  ## Reason to modify (2): Shipping / logistics
  ## ──────────────────────────────────────────

  @doc "Ships an order by selecting a carrier and creating a shipment record."
  def ship_order(%Order{status: :paid} = order, shipping_opts \\ []) do
    carrier = Keyword.get(shipping_opts, :carrier, :fedex)
    weight_kg = Keyword.get(shipping_opts, :weight_kg, 1.0)

    tracking_number = generate_tracking_number(carrier)

    shipment_cost =
      case carrier do
        :fedex -> Decimal.mult(Decimal.new("8.50"), weight_kg)
        :ups -> Decimal.mult(Decimal.new("7.80"), weight_kg)
        :dhl -> Decimal.mult(Decimal.new("9.20"), weight_kg)
        _ -> Decimal.new("10.00")
      end

    Logger.info(
      "Shipping order #{order.id} via #{carrier}, tracking: #{tracking_number}"
    )

    order
    |> Order.changeset(%{
      status: :shipped,
      carrier: carrier,
      tracking_number: tracking_number,
      shipment_cost: shipment_cost
    })
    |> Repo.update()
  end

  def ship_order(%Order{}, _opts), do: {:error, :order_not_paid}

  ## ──────────────────────────────────────────
  ## Reason to modify (3): Invoice generation
  ## ──────────────────────────────────────────

  @doc "Generates a PDF invoice and records it against the order."
  def generate_invoice(%Order{} = order, %Customer{} = customer) do
    invoice_number = "INV-#{:os.system_time(:millisecond)}"

    line_items =
      Enum.map(order.items, fn item ->
        %{
          description: item.product_name,
          qty: item.quantity,
          unit_price: item.unit_price,
          total: Decimal.mult(item.unit_price, item.quantity)
        }
      end)

    payload = %{
      invoice_number: invoice_number,
      issued_at: DateTime.utc_now(),
      customer_name: customer.name,
      customer_email: customer.email,
      line_items: line_items,
      subtotal: order.subtotal,
      tax: order.tax_amount,
      grand_total: Decimal.add(order.subtotal, order.tax_amount)
    }

    Logger.info("Generating invoice #{invoice_number} for order #{order.id}")
    {:ok, payload}
  end

  @doc "Sends an order confirmation email to the customer."
  def send_confirmation(%Order{} = order, %Customer{} = customer) do
    body = """
    Dear #{customer.name},

    Your order ##{order.id} has been confirmed.
    Total: #{order.subtotal}

    Thank you for shopping with us.
    """

    Logger.info("Sending confirmation to #{customer.email}")
    {:ok, %{to: customer.email, subject: "Order Confirmed", body: body}}
  end

  # VALIDATION: SMELL END

  ## ── Private helpers ──────────────────────

  defp fetch_discount_rate("SAVE10"), do: Decimal.new("0.10")
  defp fetch_discount_rate("SAVE20"), do: Decimal.new("0.20")
  defp fetch_discount_rate(_), do: Decimal.new("0.00")

  defp tax_rate_for_region("CA"), do: Decimal.new("0.13")
  defp tax_rate_for_region("TX"), do: Decimal.new("0.0825")
  defp tax_rate_for_region(_), do: Decimal.new("0.07")

  defp generate_tracking_number(carrier) do
    prefix = carrier |> Atom.to_string() |> String.upcase()
    "#{prefix}-#{:rand.uniform(9_999_999)}"
  end
end
```
