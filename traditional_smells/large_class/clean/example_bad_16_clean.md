```elixir
defmodule BillingManager do
  @moduledoc """
  Manages billing operations for customer accounts.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Accounts.Account
  alias MyApp.Billing.{Invoice, LineItem, PaymentAttempt}
  alias MyApp.Mailer

  @tax_rate_default 0.18
  @overdue_threshold_days 30
  @max_retry_attempts 3


  def generate_invoice(account_id, period) do
    account = Repo.get!(Account, account_id)

    line_items = calculate_line_items(account.subscriptions)
    subtotal = Enum.reduce(line_items, Decimal.new(0), &Decimal.add(&2, &1.amount))
    tax = apply_tax(subtotal, account.country_code)
    total = Decimal.add(subtotal, tax)

    invoice = %Invoice{
      account_id: account_id,
      period_start: period.start,
      period_end: period.end,
      subtotal: subtotal,
      tax: tax,
      total: total,
      status: :pending,
      issued_at: DateTime.utc_now(),
      due_at: DateTime.add(DateTime.utc_now(), 30 * 24 * 3600, :second)
    }

    case Repo.insert(invoice) do
      {:ok, saved} ->
        Logger.info("Invoice #{saved.id} generated for account #{account_id}")
        {:ok, saved}

      {:error, changeset} ->
        Logger.error("Failed to generate invoice: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  def calculate_line_items(subscriptions) do
    Enum.map(subscriptions, fn sub ->
      %LineItem{
        description: sub.plan_name,
        quantity: sub.seat_count,
        unit_price: sub.unit_price,
        amount: Decimal.mult(sub.unit_price, sub.seat_count)
      }
    end)
  end


  def apply_tax(subtotal, "BR"), do: Decimal.mult(subtotal, Decimal.from_float(0.20))
  def apply_tax(subtotal, "US"), do: Decimal.mult(subtotal, Decimal.from_float(0.08))
  def apply_tax(subtotal, "DE"), do: Decimal.mult(subtotal, Decimal.from_float(0.19))
  def apply_tax(subtotal, _), do: Decimal.mult(subtotal, Decimal.from_float(@tax_rate_default))


  def send_invoice_email(%Invoice{} = invoice, %Account{} = account) do
    pdf_path = generate_pdf_path(invoice)

    email_body = """
    Dear #{account.name},

    Please find attached your invoice ##{invoice.id} for the period
    #{Date.to_string(invoice.period_start)} to #{Date.to_string(invoice.period_end)}.

    Total due: #{invoice.total} — due by #{Date.to_string(invoice.due_at)}.

    Thank you for your business.
    """

    case Mailer.send(%{
           to: account.billing_email,
           subject: "Invoice ##{invoice.id} — #{account.name}",
           body: email_body,
           attachment: pdf_path
         }) do
      :ok ->
        Logger.info("Invoice email sent to #{account.billing_email}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to send invoice email: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def generate_pdf_path(%Invoice{id: id}) do
    "/var/invoices/#{id}.pdf"
  end


  def mark_as_paid(%Invoice{} = invoice, paid_at \\ DateTime.utc_now()) do
    invoice
    |> Invoice.changeset(%{status: :paid, paid_at: paid_at})
    |> Repo.update()
  end

  def record_payment_attempt(%Invoice{} = invoice, gateway, result) do
    attempt = %PaymentAttempt{
      invoice_id: invoice.id,
      gateway: gateway,
      result: result,
      attempted_at: DateTime.utc_now()
    }

    Repo.insert(attempt)
  end

  def retry_failed_payments(account_id) do
    invoices =
      Repo.all(
        from i in Invoice,
          where: i.account_id == ^account_id and i.status == :failed,
          where: i.retry_count < @max_retry_attempts
      )

    Enum.each(invoices, fn invoice ->
      case MyApp.PaymentGateway.charge(invoice) do
        {:ok, _} ->
          mark_as_paid(invoice)

        {:error, reason} ->
          Logger.warning("Retry failed for invoice #{invoice.id}: #{inspect(reason)}")

          invoice
          |> Invoice.changeset(%{retry_count: invoice.retry_count + 1})
          |> Repo.update()
      end
    end)
  end


  def suspend_account(account_id) do
    account = Repo.get!(Account, account_id)

    account
    |> Account.changeset(%{status: :suspended, suspended_at: DateTime.utc_now()})
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        Logger.info("Account #{account_id} suspended due to non-payment")
        {:ok, updated}

      {:error, cs} ->
        {:error, cs}
    end
  end

  def list_overdue_accounts(as_of \\ Date.utc_today()) do
    threshold = Date.add(as_of, -@overdue_threshold_days)

    Repo.all(
      from i in Invoice,
        where: i.status == :pending,
        where: i.due_at < ^threshold,
        distinct: i.account_id,
        select: i.account_id
    )
  end
end
```
