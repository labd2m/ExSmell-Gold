# Annotated Example — Code Smell

- **Smell name:** Inappropriate Intimacy
- **Expected smell location:** `InvoiceProcessor.generate_invoice/2`
- **Affected function(s):** `generate_invoice/2`
- **Short explanation:** `InvoiceProcessor` directly reaches into the internal details of `User`, `Subscription`, and `TaxProfile` modules — reading raw struct fields such as `subscription.status`, `subscription.billing_cycle`, `tax_profile.region`, `tax_profile.vat_rate`, and `user.preferred_currency` — instead of asking those modules to perform the logic themselves. This creates tight coupling: any internal change in `Subscription` or `TaxProfile` ripples into `InvoiceProcessor`.

```elixir
defmodule InvoiceProcessor do
  @moduledoc """
  Responsible for generating billing invoices for a given user and billing period.
  Invoices are stored and later used to drive payment collection.
  """

  require Logger

  alias Billing.{Invoice, InvoiceLineItem}
  alias Accounts.User
  alias Subscriptions.{Subscription, TaxProfile}
  alias Repo

  @invoice_due_days 14

  def generate_invoice(user_id, %Date.Range{} = period) do
    with {:ok, user} <- User.find(user_id),
         {:ok, subscription} <- User.active_subscription(user) do
      build_invoice(user, subscription, period)
    else
      {:error, :not_found} ->
        Logger.warning("User #{user_id} not found while generating invoice")
        {:error, :user_not_found}

      {:error, :no_active_subscription} ->
        Logger.info("User #{user_id} has no active subscription; skipping invoice")
        {:ok, :skipped}
    end
  end

  # VALIDATION: SMELL START - Inappropriate Intimacy
  # VALIDATION: This is a smell because build_invoice/3 directly inspects internal fields
  # VALIDATION: of Subscription (status, billing_cycle, plan_amount, trial_ends_at) and
  # VALIDATION: TaxProfile (region, vat_rate, sales_tax_rate), which are implementation
  # VALIDATION: details that should be encapsulated by those modules' own functions.
  defp build_invoice(user, subscription, period) do
    if subscription.status == :active && subscription.billing_cycle == :monthly do
      if is_nil(subscription.trial_ends_at) or
           Date.compare(subscription.trial_ends_at, period.first) == :lt do
        tax_profile = Subscription.tax_profile(subscription)

        tax_rate =
          if tax_profile.region in ["DE", "FR", "ES", "IT", "NL", "PT", "BE"] do
            tax_profile.vat_rate
          else
            tax_profile.sales_tax_rate
          end

        base_amount = subscription.plan_amount
        discount = calculate_discount(subscription)
        discounted = base_amount - discount
        tax_amount = Float.round(discounted * tax_rate, 2)
        total = discounted + tax_amount

        line_items = [
          %InvoiceLineItem{
            description: "Monthly subscription — #{subscription.plan_name}",
            quantity: 1,
            unit_price: base_amount,
            discount: discount,
            tax_rate: tax_rate,
            subtotal: total
          }
        ]

        invoice = %Invoice{
          user_id: user.id,
          subscription_id: subscription.id,
          period_start: period.first,
          period_end: period.last,
          line_items: line_items,
          base_amount: base_amount,
          discount_amount: discount,
          tax_amount: tax_amount,
          total_amount: total,
          currency: user.preferred_currency,
          billing_email: user.billing_email,
          issued_at: DateTime.utc_now(),
          due_at: Date.add(Date.utc_today(), @invoice_due_days),
          status: :pending
        }

        case Repo.insert(invoice) do
          {:ok, saved} ->
            Logger.info("Invoice #{saved.id} created for user #{user.id}")
            {:ok, saved}

          {:error, changeset} ->
            Logger.error("Failed to persist invoice: #{inspect(changeset.errors)}")
            {:error, :persistence_failed}
        end
      else
        Logger.info("User #{user.id} is still in trial; no invoice generated")
        {:ok, :trial_period}
      end
    else
      Logger.info("Subscription #{subscription.id} is not active-monthly; skipping")
      {:ok, :skipped}
    end
  end
  # VALIDATION: SMELL END

  defp calculate_discount(subscription) do
    case subscription.coupon_code do
      nil -> 0.0
      code -> Subscriptions.Coupon.discount_for(code, subscription.plan_amount)
    end
  end

  def mark_paid(%Invoice{} = invoice, payment_reference) do
    invoice
    |> Invoice.changeset(%{
      status: :paid,
      paid_at: DateTime.utc_now(),
      payment_reference: payment_reference
    })
    |> Repo.update()
  end

  def void_invoice(%Invoice{} = invoice, reason) do
    if invoice.status == :pending do
      invoice
      |> Invoice.changeset(%{status: :void, void_reason: reason})
      |> Repo.update()
    else
      {:error, :cannot_void_non_pending}
    end
  end
end
```
