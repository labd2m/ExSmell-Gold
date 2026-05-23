```elixir
defmodule Billing do
  @moduledoc """
  Handles invoice lifecycle for the SaaS billing pipeline.
  """

  require Logger

  @valid_currencies ~w(USD EUR GBP BRL)
  @default_due_days 30

  def create_invoice(
        customer_name,
        customer_email,
        customer_tax_id,
        currency,
        issue_date,
        due_date,
        line_description,
        unit_price,
        quantity,
        discount_percent,
        send_immediately,
        notes
      ) do
    with :ok <- validate_currency(currency),
         :ok <- validate_dates(issue_date, due_date),
         :ok <- validate_email(customer_email),
         {:ok, subtotal} <- compute_subtotal(unit_price, quantity),
         {:ok, total} <- apply_discount(subtotal, discount_percent) do
      invoice = %{
        id: generate_id(),
        customer: %{
          name: customer_name,
          email: customer_email,
          tax_id: customer_tax_id
        },
        currency: currency,
        issue_date: issue_date,
        due_date: due_date,
        line_items: [
          %{
            description: line_description,
            unit_price: unit_price,
            quantity: quantity,
            discount_percent: discount_percent,
            subtotal: subtotal,
            total: total
          }
        ],
        total: total,
        notes: notes,
        status: :draft
      }

      persisted = persist_invoice(invoice)

      if send_immediately do
        case dispatch_invoice(persisted) do
          {:ok, _} ->
            Logger.info("Invoice #{persisted.id} sent to #{customer_email}")
            {:ok, %{persisted | status: :sent}}

          {:error, reason} ->
            Logger.warning("Failed to send invoice #{persisted.id}: #{inspect(reason)}")
            {:ok, persisted}
        end
      else
        {:ok, persisted}
      end
    end
  end

  defp validate_currency(c) when c in @valid_currencies, do: :ok
  defp validate_currency(c), do: {:error, "unsupported currency: #{c}"}

  defp validate_dates(issue, due) do
    if Date.compare(due, issue) != :lt do
      :ok
    else
      {:error, "due_date must be on or after issue_date"}
    end
  end

  defp validate_email(email) do
    if String.contains?(email, "@"), do: :ok, else: {:error, "invalid email"}
  end

  defp compute_subtotal(unit_price, quantity) when unit_price >= 0 and quantity > 0 do
    {:ok, Decimal.mult(Decimal.new(unit_price), Decimal.new(quantity))}
  end
  defp compute_subtotal(_, _), do: {:error, "unit_price and quantity must be positive"}

  defp apply_discount(subtotal, 0), do: {:ok, subtotal}
  defp apply_discount(subtotal, pct) when pct > 0 and pct < 100 do
    discount = Decimal.mult(subtotal, Decimal.div(Decimal.new(pct), Decimal.new(100)))
    {:ok, Decimal.sub(subtotal, discount)}
  end
  defp apply_discount(_, _), do: {:error, "discount_percent must be between 0 and 99"}

  defp persist_invoice(invoice) do
    Map.put(invoice, :persisted_at, DateTime.utc_now())
  end

  defp dispatch_invoice(invoice) do
    Logger.debug("Dispatching invoice #{invoice.id} via email gateway")
    {:ok, invoice}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
