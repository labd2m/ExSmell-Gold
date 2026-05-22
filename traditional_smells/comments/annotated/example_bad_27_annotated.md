# Annotated Example 27

- **Smell name:** Comments
- **Expected smell location:** `BillingService.calculate_invoice/2`
- **Affected function(s):** `calculate_invoice/2`
- **Short explanation:** The function is documented using plain `#` comments instead of the `@doc` attribute, preventing ExDoc from picking up the documentation and making it invisible to tooling and documentation generators.

```elixir
defmodule MyApp.BillingService do
  @moduledoc """
  Handles invoice generation, tax calculation, and payment tracking
  for subscription-based billing cycles.
  """

  alias MyApp.Repo
  alias MyApp.Billing.{Invoice, LineItem, TaxRule}

  @tax_precision 4
  @default_currency "USD"

  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because the function is documented with plain `#` comments
  # VALIDATION: instead of `@doc`, making the documentation invisible to ExDoc and editor tooling.

  # calculate_invoice/2
  # Receives an account struct and a list of line item maps.
  # Each line item must have :description, :quantity, and :unit_price keys.
  # Applies applicable tax rules based on the account's billing region.
  # Returns {:ok, invoice} on success or {:error, reason} on failure.
  # Note: line items with zero quantity are automatically excluded.
  # The invoice date is always set to today's UTC date.
  def calculate_invoice(account, line_items) do
    # VALIDATION: SMELL END
    with {:ok, filtered_items} <- filter_valid_items(line_items),
         {:ok, tax_rule} <- fetch_tax_rule(account.billing_region),
         {:ok, subtotal} <- compute_subtotal(filtered_items),
         {:ok, tax_amount} <- apply_tax(subtotal, tax_rule),
         {:ok, invoice} <- build_invoice(account, filtered_items, subtotal, tax_amount) do
      {:ok, invoice}
    else
      {:error, :no_tax_rule} ->
        {:error, "No tax rule configured for region: #{account.billing_region}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Marks an existing invoice as paid and records the payment timestamp.

  Returns `{:ok, updated_invoice}` or `{:error, reason}`.
  """
  def mark_paid(%Invoice{} = invoice, paid_at \\ DateTime.utc_now()) do
    invoice
    |> Invoice.changeset(%{status: :paid, paid_at: paid_at})
    |> Repo.update()
  end

  @doc """
  Lists all unpaid invoices for a given account ID.
  """
  def list_unpaid(account_id) do
    Invoice
    |> Invoice.for_account(account_id)
    |> Invoice.with_status(:unpaid)
    |> Repo.all()
  end

  # --- Private helpers ---

  defp filter_valid_items(items) do
    valid = Enum.reject(items, fn item -> item.quantity <= 0 end)

    if Enum.empty?(valid) do
      {:error, "No valid line items provided"}
    else
      {:ok, valid}
    end
  end

  defp fetch_tax_rule(region) do
    case Repo.get_by(TaxRule, region: region, active: true) do
      nil -> {:error, :no_tax_rule}
      rule -> {:ok, rule}
    end
  end

  defp compute_subtotal(items) do
    total =
      Enum.reduce(items, Decimal.new(0), fn item, acc ->
        line_total = Decimal.mult(Decimal.new(item.unit_price), Decimal.new(item.quantity))
        Decimal.add(acc, line_total)
      end)

    {:ok, total}
  end

  defp apply_tax(subtotal, tax_rule) do
    rate = Decimal.div(Decimal.new(tax_rule.rate_percent), Decimal.new(100))
    tax = Decimal.round(Decimal.mult(subtotal, rate), @tax_precision)
    {:ok, tax}
  end

  defp build_invoice(account, items, subtotal, tax_amount) do
    total = Decimal.add(subtotal, tax_amount)

    params = %{
      account_id: account.id,
      currency: account.preferred_currency || @default_currency,
      subtotal: subtotal,
      tax_amount: tax_amount,
      total: total,
      status: :unpaid,
      issued_at: Date.utc_today(),
      line_items: Enum.map(items, &LineItem.from_map/1)
    }

    %Invoice{}
    |> Invoice.changeset(params)
    |> Repo.insert()
  end
end
```
