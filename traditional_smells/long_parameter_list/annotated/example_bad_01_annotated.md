# Annotated Example 01 — Long Parameter List

## Metadata

- **Smell name:** Long Parameter List
- **Expected smell location:** `Billing.create_invoice/12`
- **Affected function(s):** `create_invoice/12`
- **Short explanation:** The function accepts 12 individual parameters instead of grouping related data (customer info, billing address, line-item details) into structs or maps, making the interface confusing and error-prone.

---

```elixir
defmodule Billing do
  @moduledoc """
  Handles invoice generation and dispatch for the billing subsystem.
  """

  require Logger

  alias Billing.{Invoice, LineItem, Mailer}

  @default_currency "USD"
  @default_due_days 30

  # VALIDATION: SMELL START - Long Parameter List
  # VALIDATION: This is a smell because the function takes 12 positional parameters,
  # VALIDATION: mixing customer identity, address, financial, and metadata concerns.
  # VALIDATION: Callers must supply all values in the exact order, making mistakes easy.
  def create_invoice(
        customer_id,
        customer_name,
        customer_email,
        billing_street,
        billing_city,
        billing_state,
        billing_zip,
        billing_country,
        line_items,
        currency,
        due_days,
        send_email
      ) do
    # VALIDATION: SMELL END

    currency = currency || @default_currency
    due_days = due_days || @default_due_days

    with :ok <- validate_customer(customer_id, customer_name, customer_email),
         :ok <- validate_address(billing_street, billing_city, billing_state, billing_zip, billing_country),
         :ok <- validate_line_items(line_items),
         {:ok, totals} <- calculate_totals(line_items, currency) do
      invoice = %Invoice{
        id: generate_invoice_id(),
        customer_id: customer_id,
        customer_name: customer_name,
        customer_email: customer_email,
        billing_address: %{
          street: billing_street,
          city: billing_city,
          state: billing_state,
          zip: billing_zip,
          country: billing_country
        },
        line_items: line_items,
        subtotal: totals.subtotal,
        tax: totals.tax,
        total: totals.total,
        currency: currency,
        issued_at: DateTime.utc_now(),
        due_at: DateTime.add(DateTime.utc_now(), due_days * 86_400, :second),
        status: :pending
      }

      case save_invoice(invoice) do
        {:ok, saved} ->
          if send_email do
            Mailer.send_invoice_email(saved)
            Logger.info("Invoice #{saved.id} sent to #{customer_email}")
          end

          {:ok, saved}

        {:error, reason} ->
          Logger.error("Failed to save invoice for customer #{customer_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp validate_customer(id, name, email) do
    cond do
      is_nil(id) or id == "" -> {:error, :missing_customer_id}
      is_nil(name) or name == "" -> {:error, :missing_customer_name}
      not String.contains?(email, "@") -> {:error, :invalid_email}
      true -> :ok
    end
  end

  defp validate_address(street, city, state, zip, country) do
    cond do
      is_nil(street) or street == "" -> {:error, :missing_street}
      is_nil(city) or city == "" -> {:error, :missing_city}
      is_nil(state) or state == "" -> {:error, :missing_state}
      is_nil(zip) or zip == "" -> {:error, :missing_zip}
      is_nil(country) or country == "" -> {:error, :missing_country}
      true -> :ok
    end
  end

  defp validate_line_items([]), do: {:error, :no_line_items}
  defp validate_line_items(items) when is_list(items), do: :ok
  defp validate_line_items(_), do: {:error, :invalid_line_items}

  defp calculate_totals(line_items, _currency) do
    subtotal =
      Enum.reduce(line_items, Decimal.new(0), fn %LineItem{quantity: q, unit_price: p}, acc ->
        Decimal.add(acc, Decimal.mult(q, p))
      end)

    tax = Decimal.mult(subtotal, Decimal.new("0.08"))
    total = Decimal.add(subtotal, tax)
    {:ok, %{subtotal: subtotal, tax: tax, total: total}}
  end

  defp generate_invoice_id do
    "INV-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end

  defp save_invoice(invoice) do
    {:ok, invoice}
  end
end
```
