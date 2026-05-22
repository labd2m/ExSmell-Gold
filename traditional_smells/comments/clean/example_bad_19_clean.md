```elixir
defmodule MyApp.BillingService do
  @moduledoc """
  Handles invoice generation, proration, and tax calculations
  for subscription-based billing cycles.
  """

  alias MyApp.{Repo, Invoice, Customer, Subscription, TaxRate}
  alias MyApp.Billing.LineItem
  require Logger

  @default_currency "USD"
  @late_fee_percentage 0.015


  # calculate_invoice/2
  # Generates a complete invoice for a given customer and billing period.
  #
  # Parameters:
  #   - customer_id: integer — the ID of the customer to bill
  #   - period: map with keys :start_date and :end_date (Date.t())
  #
  # Returns {:ok, Invoice.t()} on success, or {:error, reason} on failure.
  # This function also applies applicable tax rates and late fees
  # if the previous invoice balance is overdue by more than 30 days.

  def calculate_invoice(customer_id, %{start_date: start_date, end_date: end_date}) do
    with {:ok, customer} <- fetch_customer(customer_id),
         {:ok, subscription} <- fetch_active_subscription(customer_id),
         {:ok, line_items} <- build_line_items(subscription, start_date, end_date),
         {:ok, tax_rate} <- resolve_tax_rate(customer),
         overdue_balance <- check_overdue_balance(customer_id) do
      subtotal = compute_subtotal(line_items)
      late_fee = compute_late_fee(overdue_balance)
      tax_amount = Float.round(subtotal * tax_rate.rate, 2)
      total = subtotal + late_fee + tax_amount

      invoice_params = %{
        customer_id: customer.id,
        subscription_id: subscription.id,
        currency: Map.get(customer, :preferred_currency, @default_currency),
        period_start: start_date,
        period_end: end_date,
        subtotal: subtotal,
        tax_amount: tax_amount,
        late_fee: late_fee,
        total: total,
        status: :pending,
        issued_at: Date.utc_today()
      }

      case Repo.insert(Invoice.changeset(%Invoice{}, invoice_params)) do
        {:ok, invoice} ->
          Logger.info("Invoice #{invoice.id} created for customer #{customer_id}")
          {:ok, invoice}

        {:error, changeset} ->
          Logger.error("Failed to create invoice: #{inspect(changeset.errors)}")
          {:error, :invoice_creation_failed}
      end
    end
  end

  @doc """
  Voids an existing invoice by its ID.

  Sets the invoice status to `:voided` and records the void reason.
  Returns `{:ok, invoice}` or `{:error, :not_found}`.
  """
  def void_invoice(invoice_id, reason) do
    case Repo.get(Invoice, invoice_id) do
      nil ->
        {:error, :not_found}

      invoice ->
        invoice
        |> Invoice.changeset(%{status: :voided, void_reason: reason, voided_at: DateTime.utc_now()})
        |> Repo.update()
    end
  end

  @doc """
  Applies a credit memo amount to reduce the customer's next invoice.
  """
  def apply_credit(customer_id, amount) when is_float(amount) and amount > 0 do
    case Repo.get(Customer, customer_id) do
      nil -> {:error, :customer_not_found}
      customer ->
        new_credit = (customer.credit_balance || 0.0) + amount
        customer
        |> Customer.changeset(%{credit_balance: new_credit})
        |> Repo.update()
    end
  end

  ## Private helpers

  defp fetch_customer(customer_id) do
    case Repo.get(Customer, customer_id) do
      nil -> {:error, :customer_not_found}
      customer -> {:ok, customer}
    end
  end

  defp fetch_active_subscription(customer_id) do
    case Repo.get_by(Subscription, customer_id: customer_id, status: :active) do
      nil -> {:error, :no_active_subscription}
      sub -> {:ok, sub}
    end
  end

  defp build_line_items(subscription, start_date, end_date) do
    days = Date.diff(end_date, start_date)
    items = [
      %LineItem{description: "Base plan fee", amount: subscription.monthly_price},
      %LineItem{description: "Pro-rated days (#{days})", amount: subscription.daily_rate * days}
    ]
    {:ok, items}
  end

  defp resolve_tax_rate(customer) do
    case Repo.get_by(TaxRate, region: customer.billing_region) do
      nil -> {:ok, %TaxRate{rate: 0.0}}
      rate -> {:ok, rate}
    end
  end

  defp check_overdue_balance(customer_id) do
    cutoff = Date.add(Date.utc_today(), -30)
    Repo.aggregate(
      from(i in Invoice,
        where: i.customer_id == ^customer_id and i.status == :unpaid and i.issued_at < ^cutoff,
        select: sum(i.total)
      ),
      :sum,
      :total
    ) || 0.0
  end

  defp compute_subtotal(line_items) do
    line_items
    |> Enum.map(& &1.amount)
    |> Enum.sum()
    |> Float.round(2)
  end

  defp compute_late_fee(0.0), do: 0.0
  defp compute_late_fee(overdue), do: Float.round(overdue * @late_fee_percentage, 2)
end
```
