```elixir
defmodule MyApp.BillingService do
  @moduledoc """
  Handles invoice generation, payment processing, and billing cycle management
  for subscription-based accounts.
  """

  alias MyApp.Repo
  alias MyApp.Accounts.{Account, Subscription}
  alias MyApp.Billing.{Invoice, LineItem, PaymentGateway}

  require Logger

  @invoice_due_days 30
  @tax_rate 0.08

  # Generates a new invoice for the given account and billing period.
  #
  # Parameters:
  #   - account_id: The integer ID of the account to invoice.
  #   - period: A map with :start and :end Date keys defining the billing window.
  #
  # Returns {:ok, invoice} on success or {:error, reason} on failure.
  # The invoice will include all active subscription line items plus applicable taxes.
  # Due date is set to @invoice_due_days days from today.
  def generate_invoice(account_id, period) do

    with {:ok, account} <- fetch_account(account_id),
         {:ok, subscription} <- fetch_active_subscription(account),
         line_items <- build_line_items(subscription, period),
         subtotal <- calculate_subtotal(line_items),
         tax <- Float.round(subtotal * @tax_rate, 2),
         total <- subtotal + tax,
         due_date <- Date.add(Date.utc_today(), @invoice_due_days) do
      attrs = %{
        account_id: account.id,
        period_start: period.start,
        period_end: period.end,
        line_items: line_items,
        subtotal: subtotal,
        tax: tax,
        total: total,
        due_date: due_date,
        status: :pending
      }

      case Invoice.changeset(%Invoice{}, attrs) |> Repo.insert() do
        {:ok, invoice} ->
          Logger.info("Invoice generated", invoice_id: invoice.id, account_id: account_id)
          {:ok, invoice}

        {:error, changeset} ->
          Logger.error("Failed to generate invoice", errors: changeset.errors)
          {:error, :invoice_creation_failed}
      end
    end
  end

  @doc """
  Marks an existing invoice as paid and records the payment transaction.

  ## Parameters

    - `invoice_id` – the ID of the invoice to mark as paid.
    - `payment_ref` – the external payment gateway reference string.

  ## Returns

  `{:ok, invoice}` with updated status, or `{:error, reason}`.
  """
  def mark_paid(invoice_id, payment_ref) do
    with {:ok, invoice} <- fetch_invoice(invoice_id),
         :ok <- assert_unpaid(invoice) do
      attrs = %{status: :paid, payment_ref: payment_ref, paid_at: DateTime.utc_now()}

      case Invoice.changeset(invoice, attrs) |> Repo.update() do
        {:ok, updated} ->
          Logger.info("Invoice marked paid", invoice_id: invoice_id)
          {:ok, updated}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Voids an invoice that has not yet been paid.
  """
  def void_invoice(invoice_id) do
    with {:ok, invoice} <- fetch_invoice(invoice_id),
         :ok <- assert_unpaid(invoice) do
      invoice
      |> Invoice.changeset(%{status: :void})
      |> Repo.update()
    end
  end

  # --- Private helpers ---

  defp fetch_account(account_id) do
    case Repo.get(Account, account_id) do
      nil -> {:error, :account_not_found}
      account -> {:ok, account}
    end
  end

  defp fetch_active_subscription(%Account{id: account_id}) do
    case Repo.get_by(Subscription, account_id: account_id, status: :active) do
      nil -> {:error, :no_active_subscription}
      sub -> {:ok, sub}
    end
  end

  defp fetch_invoice(invoice_id) do
    case Repo.get(Invoice, invoice_id) do
      nil -> {:error, :invoice_not_found}
      invoice -> {:ok, invoice}
    end
  end

  defp assert_unpaid(%Invoice{status: :pending}), do: :ok
  defp assert_unpaid(_), do: {:error, :invoice_not_pending}

  defp build_line_items(%Subscription{plan: plan, seats: seats}, _period) do
    [
      %LineItem{description: "#{plan} plan", quantity: seats, unit_price: plan_price(plan)},
      %LineItem{description: "Support", quantity: 1, unit_price: 49.00}
    ]
  end

  defp calculate_subtotal(line_items) do
    Enum.reduce(line_items, 0.0, fn item, acc ->
      acc + item.quantity * item.unit_price
    end)
  end

  defp plan_price(:starter), do: 29.00
  defp plan_price(:professional), do: 99.00
  defp plan_price(:enterprise), do: 299.00
  defp plan_price(_), do: 0.0
end
```
