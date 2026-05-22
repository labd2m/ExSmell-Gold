# Annotated Example 01

## Metadata

- **Smell name:** Comments
- **Expected smell location:** `BillingService.calculate_invoice_total/1`
- **Affected function(s):** `calculate_invoice_total/1`
- **Short explanation:** The function is documented entirely through inline explanatory comments instead of using Elixir's `@doc` attribute. This bypasses the standard documentation system, making the documentation invisible to tools like `mix docs`, `IEx.h/1`, and ExDoc.

---

## Code

```elixir
defmodule BillingService do
  @moduledoc """
  Handles invoice generation and billing operations for tenant accounts.
  """

  alias BillingService.{Invoice, LineItem, TaxEngine, DiscountPolicy}

  @default_currency "USD"
  @max_discount_rate 0.30

  # calculate_invoice_total/1
  # Receives an invoice struct and computes the final total to be charged
  # to the customer. The computation follows these steps:
  #   1. Sum all line item subtotals (quantity * unit_price).
  #   2. Apply any applicable discount from the DiscountPolicy module.
  #   3. Pass the discounted subtotal through the TaxEngine to obtain
  #      the tax amount for the invoice's jurisdiction.
  #   4. Return a map containing :subtotal, :discount, :tax, and :total.
  # Returns {:ok, result_map} on success or {:error, reason} on failure.
  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because the function is fully documented using
  # plain inline comments instead of an @doc attribute, making this documentation
  # invisible to ExDoc, IEx.h/1, and any tooling that relies on @doc strings.
  def calculate_invoice_total(%Invoice{} = invoice) do
    with {:ok, line_items} <- fetch_line_items(invoice.id),
         {:ok, subtotal} <- sum_line_items(line_items),
         {:ok, discount} <- DiscountPolicy.resolve(invoice.account_id, subtotal),
         {:ok, discounted} <- apply_discount(subtotal, discount),
         {:ok, tax} <- TaxEngine.calculate(discounted, invoice.jurisdiction) do
      total = discounted + tax

      result = %{
        invoice_id: invoice.id,
        currency: invoice.currency || @default_currency,
        subtotal: subtotal,
        discount: discount,
        tax: tax,
        total: total
      }

      {:ok, result}
    else
      {:error, reason} -> {:error, reason}
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Marks an invoice as paid and records the payment timestamp.
  """
  def mark_as_paid(%Invoice{} = invoice, paid_at \\ DateTime.utc_now()) do
    invoice
    |> Invoice.changeset(%{status: :paid, paid_at: paid_at})
    |> Repo.update()
  end

  @doc """
  Voids an invoice if it has not already been paid.
  """
  def void_invoice(%Invoice{status: :paid}), do: {:error, :already_paid}

  def void_invoice(%Invoice{} = invoice) do
    invoice
    |> Invoice.changeset(%{status: :void})
    |> Repo.update()
  end

  defp fetch_line_items(invoice_id) do
    case Repo.all(LineItem, invoice_id: invoice_id) do
      [] -> {:error, :no_line_items}
      items -> {:ok, items}
    end
  end

  defp sum_line_items(line_items) do
    total =
      Enum.reduce(line_items, Decimal.new(0), fn item, acc ->
        subtotal = Decimal.mult(item.quantity, item.unit_price)
        Decimal.add(acc, subtotal)
      end)

    {:ok, total}
  end

  defp apply_discount(subtotal, discount_rate)
       when discount_rate > @max_discount_rate do
    {:error, :discount_exceeds_maximum}
  end

  defp apply_discount(subtotal, discount_rate) do
    discounted =
      subtotal
      |> Decimal.mult(Decimal.sub(Decimal.new(1), discount_rate))

    {:ok, discounted}
  end
end
```
