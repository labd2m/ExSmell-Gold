```elixir
defmodule MyApp.Billing.InvoiceGenerator do
  @moduledoc """
  Generates invoice documents for each supported invoice type.
  Invoices are stored in the database and optionally rendered to PDF.
  Each type follows its own numbering series and document structure.
  """

  alias MyApp.Billing.{NumberSequence, TaxEngine, LineItemBuilder}
  alias MyApp.Repo

  require Logger

  def generate(:standard, %{order: order, customer: customer}) do
    number = NumberSequence.next(:standard)
    tax_result = TaxEngine.apply(:standard, order.line_items)

    invoice = %MyApp.Billing.Invoice{
      type: :standard,
      number: number,
      series: "NF",
      customer_id: customer.id,
      order_id: order.id,
      line_items: LineItemBuilder.from_order(order),
      subtotal: order.subtotal,
      tax_amount: tax_result.total_tax,
      total: order.subtotal + tax_result.total_tax,
      tax_breakdown: tax_result.breakdown,
      issued_at: DateTime.utc_now(),
      due_at: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second),
      status: :pending
    }

    case Repo.insert(invoice) do
      {:ok, inv} ->
        Logger.info("Standard invoice generated", invoice_id: inv.id, number: number)
        {:ok, inv}

      {:error, changeset} ->
        {:error, {:invoice_insert_failed, changeset}}
    end
  end

  def generate(:recurring, %{subscription: subscription, customer: customer}) do
    number = NumberSequence.next(:recurring)
    period_items = LineItemBuilder.from_subscription(subscription)
    tax_result = TaxEngine.apply(:recurring, period_items)

    invoice = %MyApp.Billing.Invoice{
      type: :recurring,
      number: number,
      series: "REC",
      customer_id: customer.id,
      subscription_id: subscription.id,
      line_items: period_items,
      billing_period_start: subscription.current_period_start,
      billing_period_end: subscription.current_period_end,
      subtotal: subscription.amount,
      tax_amount: tax_result.total_tax,
      total: subscription.amount + tax_result.total_tax,
      tax_breakdown: tax_result.breakdown,
      issued_at: DateTime.utc_now(),
      due_at: subscription.current_period_end,
      status: :pending
    }

    case Repo.insert(invoice) do
      {:ok, inv} ->
        Logger.info("Recurring invoice generated", invoice_id: inv.id, subscription_id: subscription.id)
        {:ok, inv}

      {:error, changeset} ->
        {:error, {:invoice_insert_failed, changeset}}
    end
  end

  def generate(:proforma, %{quote: quote, customer: customer}) do
    number = NumberSequence.next(:proforma)
    tax_result = TaxEngine.apply(:proforma, quote.line_items)

    invoice = %MyApp.Billing.Invoice{
      type: :proforma,
      number: number,
      series: "PRO",
      customer_id: customer.id,
      quote_id: quote.id,
      line_items: LineItemBuilder.from_quote(quote),
      subtotal: quote.subtotal,
      tax_amount: tax_result.total_tax,
      total: quote.subtotal + tax_result.total_tax,
      tax_breakdown: tax_result.breakdown,
      issued_at: DateTime.utc_now(),
      due_at: DateTime.add(DateTime.utc_now(), 7 * 86_400, :second),
      status: :draft
    }

    case Repo.insert(invoice) do
      {:ok, inv} ->
        Logger.info("Proforma invoice generated", invoice_id: inv.id, quote_id: quote.id)
        {:ok, inv}

      {:error, changeset} ->
        {:error, {:invoice_insert_failed, changeset}}
    end
  end

  def generate(unknown_type, _params) do
    {:error, {:unsupported_invoice_type, unknown_type}}
  end
end

defmodule MyApp.Billing.TaxEngine do
  @moduledoc """
  Applies tax calculation rules per invoice type.
  Standard and recurring invoices are subject to full ISS/ICMS treatment.
  Proforma invoices carry indicative taxes only (no official fiscal impact).
  """

  @iss_rate 0.05
  @icms_rate 0.12

  def apply(:standard, line_items) do
    taxable_total = Enum.sum(Enum.map(line_items, & &1.amount))
    iss = Float.round(taxable_total * @iss_rate, 2)
    icms = Float.round(taxable_total * @icms_rate, 2)

    %{
      total_tax: iss + icms,
      breakdown: [
        %{tax: :iss, rate: @iss_rate, amount: iss},
        %{tax: :icms, rate: @icms_rate, amount: icms}
      ]
    }
  end

  def apply(:recurring, line_items) do
    taxable_total = Enum.sum(Enum.map(line_items, & &1.amount))
    iss = Float.round(taxable_total * @iss_rate, 2)

    %{
      total_tax: iss,
      breakdown: [%{tax: :iss, rate: @iss_rate, amount: iss}]
    }
  end

  def apply(:proforma, line_items) do
    indicative_total = Enum.sum(Enum.map(line_items, & &1.amount))
    indicative_tax = Float.round(indicative_total * (@iss_rate + @icms_rate), 2)

    %{
      total_tax: indicative_tax,
      breakdown: [%{tax: :indicative, rate: @iss_rate + @icms_rate, amount: indicative_tax}]
    }
  end

  def apply(unknown_type, _line_items) do
    raise ArgumentError, "No tax rule defined for invoice type: #{inspect(unknown_type)}"
  end
end

defmodule MyApp.Billing.DeliveryService do
  @moduledoc """
  Delivers generated invoices to customers via the appropriate channel.
  Delivery strategy differs per type: standard invoices go by email with
  PDF attachment, recurring invoices trigger in-app notifications, and
  proforma invoices are shared via a secure link.
  """

  alias MyApp.Mailer
  alias MyApp.Notifications.Dispatcher

  def deliver(:standard, invoice) do
    email = Mailer.build_invoice_email(invoice, :pdf_attachment)

    case Mailer.deliver(email) do
      {:ok, _} ->
        mark_delivered(invoice, :email)
        {:ok, :delivered_by_email}

      {:error, reason} ->
        {:error, {:email_delivery_failed, reason}}
    end
  end

  def deliver(:recurring, invoice) do
    notification = %{
      type: :invoice_available,
      channel: :in_app,
      recipient_id: invoice.customer_id,
      payload: %{invoice_id: invoice.id, amount: invoice.total, due_at: invoice.due_at}
    }

    case Dispatcher.dispatch(notification) do
      {:ok, _} ->
        mark_delivered(invoice, :in_app)
        {:ok, :delivered_in_app}

      {:error, reason} ->
        {:error, {:notification_failed, reason}}
    end
  end

  def deliver(:proforma, invoice) do
    link = MyApp.SecureLinks.generate("/invoices/#{invoice.id}/preview", ttl: 7 * 86_400)
    email = Mailer.build_invoice_email(invoice, :secure_link, link: link)

    case Mailer.deliver(email) do
      {:ok, _} ->
        mark_delivered(invoice, :secure_link)
        {:ok, :delivered_by_secure_link}

      {:error, reason} ->
        {:error, {:email_delivery_failed, reason}}
    end
  end

  def deliver(unknown_type, _invoice) do
    {:error, {:unsupported_invoice_type, unknown_type}}
  end

  defp mark_delivered(invoice, channel) do
    MyApp.Repo.update_all(
      MyApp.Billing.Invoice,
      [set: [delivered_via: channel, delivered_at: DateTime.utc_now()]],
      where: [id: invoice.id]
    )
  end
end
```
