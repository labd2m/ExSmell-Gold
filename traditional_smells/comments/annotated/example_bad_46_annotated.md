# Annotated Example — Code Smell: Comments

- **Smell name:** Comments
- **Expected smell location:** `BillingInvoice` module, function `generate_invoice/2`
- **Affected function(s):** `generate_invoice/2`, `apply_discount/2`, `calculate_tax/2`
- **Short explanation:** These functions are documented using plain `#` comments instead of the proper `@doc` attribute. Elixir provides first-class documentation through `@doc` and `@moduledoc`, which integrates with ExDoc, IEx `h/1`, and tooling. Using prose comments for documentation bypasses all of that infrastructure and cannot be introspected at runtime.

```elixir
defmodule MyApp.Billing.Invoice do
  @moduledoc false

  alias MyApp.Billing.{LineItem, Customer, TaxRate}
  alias MyApp.Repo

  @default_currency "USD"
  @invoice_prefix "INV"

  # Generates a new invoice for the given customer and list of line items.
  # The customer must already exist in the system.
  # line_items should be a list of %LineItem{} structs with :description,
  # :quantity, and :unit_price fields populated.
  # Returns {:ok, invoice} on success or {:error, reason} on failure.
  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because `generate_invoice/2` is documented
  # VALIDATION: with plain `#` comments instead of an `@doc` attribute.
  # VALIDATION: This documentation is invisible to `IEx.Helpers.h/1`,
  # VALIDATION: ExDoc, and any editor tooling that reads `@doc` strings.
  def generate_invoice(%Customer{} = customer, line_items) when is_list(line_items) do
    # VALIDATION: SMELL END
    with {:ok, _} <- validate_line_items(line_items),
         subtotal <- compute_subtotal(line_items),
         {:ok, discount} <- apply_discount(customer, subtotal),
         {:ok, tax} <- calculate_tax(customer, subtotal - discount) do
      invoice = %{
        number: build_invoice_number(),
        customer_id: customer.id,
        currency: @default_currency,
        line_items: line_items,
        subtotal: subtotal,
        discount: discount,
        tax: tax,
        total: subtotal - discount + tax,
        issued_at: DateTime.utc_now(),
        due_at: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second),
        status: :draft
      }

      {:ok, invoice}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Applies a percentage or flat discount to the subtotal based on the
  # customer's tier. Platinum customers receive 15%, Gold 10%, Silver 5%.
  # Returns {:ok, discount_amount} or {:error, :unknown_tier}.
  def apply_discount(%Customer{tier: tier}, subtotal) do
    rate =
      case tier do
        :platinum -> 0.15
        :gold -> 0.10
        :silver -> 0.05
        :standard -> 0.0
        _ -> :unknown
      end

    if rate == :unknown do
      {:error, :unknown_tier}
    else
      {:ok, Float.round(subtotal * rate, 2)}
    end
  end

  # Calculates the applicable sales tax for the customer based on their
  # billing address country and state. Uses the TaxRate lookup table.
  # Returns {:ok, tax_amount} or {:error, :no_tax_rate_found}.
  def calculate_tax(%Customer{billing_address: address}, taxable_amount) do
    case Repo.get_by(TaxRate, country: address.country, region: address.state) do
      nil ->
        {:error, :no_tax_rate_found}

      %TaxRate{rate: rate} ->
        {:ok, Float.round(taxable_amount * rate, 2)}
    end
  end

  defp validate_line_items([]), do: {:error, :empty_line_items}

  defp validate_line_items(items) do
    invalid =
      Enum.any?(items, fn
        %LineItem{quantity: q, unit_price: p} when q > 0 and p >= 0 -> false
        _ -> true
      end)

    if invalid, do: {:error, :invalid_line_item}, else: {:ok, :valid}
  end

  defp compute_subtotal(line_items) do
    Enum.reduce(line_items, 0.0, fn %LineItem{quantity: q, unit_price: p}, acc ->
      acc + q * p
    end)
    |> Float.round(2)
  end

  defp build_invoice_number do
    suffix =
      :crypto.strong_rand_bytes(6)
      |> Base.encode16()

    "#{@invoice_prefix}-#{suffix}"
  end
end
```
