# Code Smell Annotation

- **Smell name:** Large Class (Large Module)
- **Expected smell location:** The entire `BillingManager` module
- **Affected function(s):** All functions — `create_invoice/2`, `finalize_invoice/1`, `apply_tax/2`, `calculate_line_items/1`, `send_invoice_email/2`, `process_payment/2`, `issue_refund/2`, `record_payment_failure/2`, `get_subscription_plan/1`, `renew_subscription/1`, `cancel_subscription/2`, `generate_billing_report/2`
- **Short explanation:** `BillingManager` handles at least four unrelated business concerns — invoice lifecycle, tax calculation, payment processing, and subscription management — inside a single module. Each concern has its own distinct set of functions that could be cohesively grouped in separate modules (e.g., `Invoice`, `TaxCalculator`, `PaymentProcessor`, `SubscriptionManager`), reducing the size and increasing cohesion.

```elixir
# VALIDATION: SMELL START - Large Class (Large Module)
# VALIDATION: This is a smell because BillingManager conflates invoice creation,
# tax logic, email dispatch, payment processing, refunds, and subscription
# management into one module. Each of these is a distinct business rule that
# should live in its own cohesive module.
defmodule MyApp.BillingManager do
  @moduledoc """
  Handles all billing-related operations for the platform.
  """

  require Logger
  alias MyApp.Repo
  alias MyApp.Billing.{Invoice, LineItem, Payment, Subscription}
  alias MyApp.Accounts.User
  alias MyApp.Mailer

  @tax_rates %{
    "BR" => 0.12,
    "US" => 0.08,
    "DE" => 0.19,
    "default" => 0.10
  }

  @subscription_plans %{
    "starter"    => %{price: 29_00, max_users: 5,   features: [:basic]},
    "growth"     => %{price: 79_00, max_users: 20,  features: [:basic, :analytics]},
    "enterprise" => %{price: 299_00, max_users: nil, features: [:basic, :analytics, :sso]}
  }

  # -------------------------------------------------------------------
  # Invoice management
  # -------------------------------------------------------------------

  def create_invoice(%User{} = user, line_items) when is_list(line_items) do
    subtotal = calculate_line_items(line_items)
    tax      = apply_tax(subtotal, user.country)
    total    = subtotal + tax

    attrs = %{
      user_id:    user.id,
      subtotal:   subtotal,
      tax_amount: tax,
      total:      total,
      status:     :draft,
      due_date:   Date.add(Date.utc_today(), 30),
      line_items: line_items
    }

    case Repo.insert(Invoice.changeset(%Invoice{}, attrs)) do
      {:ok, invoice} ->
        Logger.info("Invoice #{invoice.id} created for user #{user.id}")
        {:ok, invoice}

      {:error, changeset} ->
        Logger.error("Failed to create invoice: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  def finalize_invoice(%Invoice{status: :draft} = invoice) do
    case Repo.update(Invoice.changeset(invoice, %{status: :open})) do
      {:ok, updated} ->
        send_invoice_email(updated, :finalized)
        {:ok, updated}

      {:error, _} = err ->
        err
    end
  end

  def finalize_invoice(%Invoice{status: status}),
    do: {:error, "Cannot finalize invoice in status: #{status}"}

  def calculate_line_items(line_items) do
    Enum.reduce(line_items, 0, fn %{quantity: qty, unit_price: price}, acc ->
      acc + qty * price
    end)
  end

  def apply_tax(subtotal, country) do
    rate = Map.get(@tax_rates, country, @tax_rates["default"])
    round(subtotal * rate)
  end

  # -------------------------------------------------------------------
  # Email notifications for invoices
  # -------------------------------------------------------------------

  def send_invoice_email(%Invoice{} = invoice, :finalized) do
    user = Repo.get!(User, invoice.user_id)

    Mailer.deliver(%{
      to:      user.email,
      subject: "Your invoice ##{invoice.id} is ready",
      body:    "Total due: #{format_currency(invoice.total)}. Due by #{invoice.due_date}."
    })
  end

  def send_invoice_email(%Invoice{} = invoice, :paid) do
    user = Repo.get!(User, invoice.user_id)

    Mailer.deliver(%{
      to:      user.email,
      subject: "Payment received for invoice ##{invoice.id}",
      body:    "Thank you! Your payment of #{format_currency(invoice.total)} was received."
    })
  end

  # -------------------------------------------------------------------
  # Payment processing
  # -------------------------------------------------------------------

  def process_payment(%Invoice{status: :open} = invoice, payment_method) do
    charge_result = MyApp.PaymentGateway.charge(%{
      amount:   invoice.total,
      currency: "USD",
      method:   payment_method,
      metadata: %{invoice_id: invoice.id}
    })

    case charge_result do
      {:ok, charge} ->
        payment = Repo.insert!(%Payment{
          invoice_id:       invoice.id,
          amount:           invoice.total,
          gateway_charge_id: charge.id,
          status:           :succeeded
        })

        Repo.update!(Invoice.changeset(invoice, %{status: :paid, paid_at: DateTime.utc_now()}))
        send_invoice_email(invoice, :paid)
        {:ok, payment}

      {:error, reason} ->
        record_payment_failure(invoice, reason)
        {:error, reason}
    end
  end

  def process_payment(%Invoice{status: status}, _method),
    do: {:error, "Invoice status #{status} is not payable"}

  def issue_refund(%Payment{status: :succeeded} = payment, amount_cents)
      when amount_cents > 0 do
    if amount_cents > payment.amount do
      {:error, "Refund amount exceeds original payment"}
    else
      case MyApp.PaymentGateway.refund(payment.gateway_charge_id, amount_cents) do
        {:ok, _refund} ->
          Repo.update!(Payment.changeset(payment, %{refunded_amount: amount_cents, status: :refunded}))
          {:ok, :refund_issued}

        {:error, _} = err ->
          err
      end
    end
  end

  def issue_refund(_, _), do: {:error, "Payment is not eligible for refund"}

  defp record_payment_failure(%Invoice{} = invoice, reason) do
    Logger.warning("Payment failed for invoice #{invoice.id}: #{inspect(reason)}")

    Repo.insert!(%Payment{
      invoice_id: invoice.id,
      amount:     invoice.total,
      status:     :failed,
      failure_reason: to_string(reason)
    })
  end

  # -------------------------------------------------------------------
  # Subscription management
  # -------------------------------------------------------------------

  def get_subscription_plan(plan_name) do
    case Map.fetch(@subscription_plans, plan_name) do
      {:ok, plan} -> {:ok, Map.put(plan, :name, plan_name)}
      :error      -> {:error, "Unknown plan: #{plan_name}"}
    end
  end

  def renew_subscription(%Subscription{status: :active} = sub) do
    {:ok, plan}  = get_subscription_plan(sub.plan_name)
    user         = Repo.get!(User, sub.user_id)
    {:ok, invoice} = create_invoice(user, [%{quantity: 1, unit_price: plan.price,
                                              description: "#{sub.plan_name} plan renewal"}])

    new_period_end = Date.add(sub.current_period_end, 30)

    Repo.update!(Subscription.changeset(sub, %{
      current_period_end: new_period_end,
      renewal_invoice_id: invoice.id
    }))

    {:ok, invoice}
  end

  def renew_subscription(%Subscription{status: status}),
    do: {:error, "Cannot renew subscription with status: #{status}"}

  def cancel_subscription(%Subscription{} = sub, reason) do
    Repo.update!(Subscription.changeset(sub, %{
      status:       :canceled,
      canceled_at:  DateTime.utc_now(),
      cancel_reason: reason
    }))

    user = Repo.get!(User, sub.user_id)

    Mailer.deliver(%{
      to:      user.email,
      subject: "Your subscription has been canceled",
      body:    "We're sorry to see you go. Reason: #{reason}."
    })

    :ok
  end

  # -------------------------------------------------------------------
  # Reporting
  # -------------------------------------------------------------------

  def generate_billing_report(start_date, end_date) do
    invoices = Repo.all(
      from i in Invoice,
        where: i.inserted_at >= ^start_date and i.inserted_at <= ^end_date,
        preload: [:payments]
    )

    total_invoiced = Enum.reduce(invoices, 0, & &1.total + &2)
    total_paid     = invoices |> Enum.filter(&(&1.status == :paid)) |> Enum.reduce(0, & &1.total + &2)
    total_failed   = invoices |> Enum.filter(&(&1.status == :open)) |> length()

    %{
      period:          "#{start_date} to #{end_date}",
      total_invoiced:  total_invoiced,
      total_collected: total_paid,
      open_invoices:   total_failed,
      invoice_count:   length(invoices)
    }
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp format_currency(cents) do
    dollars = cents / 100
    :io_lib.format("$~.2f", [dollars]) |> IO.iodata_to_binary()
  end
end
# VALIDATION: SMELL END
```
