```elixir
defmodule Commerce.OrderValidator do
  @moduledoc """
  Validates an order submission through a sequential, composable pipeline
  of pure validation functions. Each stage receives the order map and the
  accumulated context from prior stages, returning either an enriched context
  or a typed error atom. The pipeline halts at the first failure so callers
  receive a precise, machine-readable error code rather than a vague message.
  """

  alias Commerce.{Inventory, Pricing, TaxEngine}

  @type order_input :: %{
          required(:customer_id) => binary(),
          required(:items) => [item()],
          required(:shipping_address) => map(),
          optional(:coupon_code) => binary() | nil
        }

  @type item :: %{
          required(:sku_id) => binary(),
          required(:quantity) => pos_integer()
        }

  @type validation_error ::
          :missing_customer
          | :no_items
          | :quantity_exceeds_stock
          | :item_not_available
          | :invalid_shipping_address
          | :coupon_expired
          | :coupon_not_applicable
          | :subtotal_below_minimum

  @type validation_context :: %{
          order: order_input(),
          enriched_items: [map()],
          subtotal_cents: non_neg_integer(),
          discount_cents: non_neg_integer(),
          tax_cents: non_neg_integer(),
          total_cents: non_neg_integer()
        }

  @minimum_order_cents 500

  @doc """
  Runs the full validation pipeline for `order_input`. Returns
  `{:ok, validation_context}` on success or `{:error, validation_error}`
  on the first failing stage.
  """
  @spec validate(order_input()) ::
          {:ok, validation_context()} | {:error, validation_error()}
  def validate(order_input) when is_map(order_input) do
    with :ok <- check_customer(order_input),
         :ok <- check_items_present(order_input),
         {:ok, enriched_items} <- check_availability(order_input.items),
         {:ok, address} <- validate_address(order_input.shipping_address),
         {:ok, subtotal} <- compute_subtotal(enriched_items),
         {:ok, discount} <- apply_coupon(order_input[:coupon_code], subtotal),
         {:ok, tax} <- compute_tax(subtotal - discount, address),
         :ok <- check_minimum(subtotal - discount) do
      ctx = %{
        order: order_input,
        enriched_items: enriched_items,
        subtotal_cents: subtotal,
        discount_cents: discount,
        tax_cents: tax,
        total_cents: subtotal - discount + tax
      }

      {:ok, ctx}
    end
  end

  # ---------------------------------------------------------------------------
  # Validation stages
  # ---------------------------------------------------------------------------

  defp check_customer(%{customer_id: id}) when is_binary(id) and byte_size(id) > 0, do: :ok
  defp check_customer(_), do: {:error, :missing_customer}

  defp check_items_present(%{items: [_ | _]}), do: :ok
  defp check_items_present(_), do: {:error, :no_items}

  defp check_availability(items) do
    results =
      Enum.map(items, fn %{sku_id: sku_id, quantity: qty} ->
        case Inventory.check_stock(sku_id, qty) do
          {:ok, price_cents} ->
            {:ok, %{sku_id: sku_id, quantity: qty, unit_cents: price_cents}}

          {:error, :insufficient_stock} ->
            {:error, :quantity_exceeds_stock}

          {:error, :not_found} ->
            {:error, :item_not_available}
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, item} -> item end)}
      error -> error
    end
  end

  defp validate_address(address) when is_map(address) do
    required = [:line1, :city, :postal_code, :country_code]
    missing = Enum.filter(required, &(not Map.has_key?(address, &1)))

    if missing == [] do
      {:ok, address}
    else
      {:error, :invalid_shipping_address}
    end
  end

  defp validate_address(_), do: {:error, :invalid_shipping_address}

  defp compute_subtotal(enriched_items) do
    total = Enum.reduce(enriched_items, 0, fn item, acc ->
      acc + item.quantity * item.unit_cents
    end)

    {:ok, total}
  end

  defp apply_coupon(nil, _subtotal), do: {:ok, 0}

  defp apply_coupon(code, subtotal) when is_binary(code) do
    case Pricing.resolve_coupon(code, subtotal) do
      {:ok, discount_cents} -> {:ok, discount_cents}
      {:error, :expired} -> {:error, :coupon_expired}
      {:error, :not_applicable} -> {:error, :coupon_not_applicable}
    end
  end

  defp compute_tax(taxable_amount, address) do
    TaxEngine.calculate(taxable_amount, address.country_code, address[:state])
  end

  defp check_minimum(net_cents) when net_cents >= @minimum_order_cents, do: :ok
  defp check_minimum(_), do: {:error, :subtotal_below_minimum}
end
```
