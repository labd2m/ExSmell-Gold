```elixir
defmodule Commerce.CheckoutOrchestrator do
  @moduledoc """
  Orchestrates the multi-step checkout process: cart validation, address
  verification, payment authorisation, and order creation. Each step is
  delegated to a focused module. The pipeline halts at the first failure
  and returns a typed error so the caller can route to the appropriate
  recovery flow without catching exceptions.
  """

  require Logger

  alias Commerce.{CartAggregate, AddressValidator, TaxCalculator}
  alias Payments.GatewayClient
  alias Orders.Repository, as: OrderRepo
  alias Notifications.Dispatcher, as: Notify

  @type cart_id :: String.t()
  @type customer_id :: String.t()
  @type shipping_address :: map()
  @type payment_source :: %{token: String.t(), idempotency_key: String.t()}

  @type checkout_params :: %{
          cart_id: cart_id(),
          customer_id: customer_id(),
          shipping_address: shipping_address(),
          billing_address: shipping_address(),
          payment_source: payment_source(),
          currency: String.t()
        }

  @type checkout_result ::
          {:ok, %{order_id: String.t(), total_cents: non_neg_integer()}}
          | {:error,
             :empty_cart
             | :invalid_address
             | :payment_failed
             | :order_creation_failed
             | term()}

  @doc """
  Runs the full checkout pipeline for the given params. Returns the created
  order ID and total on success, or a typed error at the first failure point.
  """
  @spec checkout(checkout_params()) :: checkout_result()
  def checkout(%{cart_id: cart_id, customer_id: customer_id} = params) do
    with {:ok, items} <- fetch_and_validate_cart(cart_id),
         {:ok, address} <- validate_address(params.shipping_address),
         {:ok, tax} <- compute_tax(items, address, params.currency),
         {:ok, total_cents} <- compute_total(items, tax),
         {:ok, auth} <- authorise_payment(params.payment_source, total_cents, params.currency),
         {:ok, order} <- create_order(customer_id, items, address, tax, total_cents, auth) do
      notify_customer(customer_id, order)
      log_success(customer_id, order.id, total_cents)
      {:ok, %{order_id: order.id, total_cents: total_cents}}
    end
  end

  defp fetch_and_validate_cart(cart_id) do
    items = CartAggregate.items(cart_id)

    if Enum.empty?(items) do
      {:error, :empty_cart}
    else
      {:ok, items}
    end
  end

  defp validate_address(address) do
    case AddressValidator.validate(address) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, _reason} -> {:error, :invalid_address}
    end
  end

  defp compute_tax(items, address, currency) do
    line_items = Enum.map(items, fn i ->
      %{subtotal_cents: i.unit_price_cents * i.quantity, tax_category: :standard}
    end)

    tax = TaxCalculator.calculate(line_items, address["country_code"] || "US")
    {:ok, %{total_tax_cents: tax.total_tax_cents, currency: currency}}
  end

  defp compute_total(items, tax) do
    subtotal = Enum.sum_by(items, fn i -> i.unit_price_cents * i.quantity end)
    {:ok, subtotal + tax.total_tax_cents}
  end

  defp authorise_payment(%{token: token, idempotency_key: idem_key}, amount_cents, currency) do
    params = %{amount_cents: amount_cents, currency: currency,
               source_token: token, idempotency_key: idem_key}

    case GatewayClient.charge(params) do
      {:ok, charge} -> {:ok, charge}
      {:error, _reason} -> {:error, :payment_failed}
    end
  end

  defp create_order(customer_id, items, address, tax, total_cents, auth) do
    attrs = %{
      customer_id: customer_id,
      line_items: items,
      shipping_address: address,
      tax_cents: tax.total_tax_cents,
      total_cents: total_cents,
      payment_charge_id: auth.charge_id,
      status: "confirmed"
    }

    case OrderRepo.create(attrs) do
      {:ok, order} -> {:ok, order}
      {:error, _} -> {:error, :order_creation_failed}
    end
  end

  defp notify_customer(customer_id, order) do
    Notify.dispatch(%{
      type: :order_placed,
      recipient_id: customer_id,
      payload: %{order_id: order.id, total_cents: order.total_cents}
    })
  end

  defp log_success(customer_id, order_id, total_cents) do
    Logger.info("[Checkout] #{customer_id} → order #{order_id}, #{total_cents} cents")
  end
end
```
