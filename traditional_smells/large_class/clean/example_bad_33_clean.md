```elixir
defmodule Billing do
  @moduledoc """
  Handles invoice creation, tax, discounts, notifications, PDF export,
  and payment recording for the platform's billing subsystem.
  """

  require Logger
  alias Billing.Repo
  alias Billing.Invoice
  alias Billing.Payment

  @tax_rates %{
    "BR" => 0.12,
    "US" => 0.08,
    "DE" => 0.19,
    "default" => 0.10
  }

  @overdue_threshold_days 30


  def create_invoice(user, line_items) do
    subtotal =
      Enum.reduce(line_items, Decimal.new("0"), fn item, acc ->
        Decimal.add(acc, Decimal.mult(item.unit_price, item.quantity))
      end)

    attrs = %{
      user_id: user.id,
      line_items: line_items,
      subtotal: subtotal,
      status: :pending,
      issued_at: DateTime.utc_now(),
      due_at: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
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

  def archive_invoice(%Invoice{} = invoice) do
    invoice
    |> Invoice.changeset(%{status: :archived})
    |> Repo.update()
  end

  def list_overdue_invoices(user_id) do
    threshold = DateTime.add(DateTime.utc_now(), -@overdue_threshold_days * 86_400, :second)

    Invoice
    |> Invoice.for_user(user_id)
    |> Invoice.due_before(threshold)
    |> Invoice.with_status(:pending)
    |> Repo.all()
  end


  def calculate_tax(subtotal, country_code) do
    rate = Map.get(@tax_rates, country_code, @tax_rates["default"])
    tax = Decimal.mult(subtotal, Decimal.from_float(rate))
    total = Decimal.add(subtotal, tax)
    %{subtotal: subtotal, tax: tax, total: total, rate: rate}
  end


  def apply_coupon(invoice, nil), do: {:ok, invoice}

  def apply_coupon(invoice, coupon_code) do
    case fetch_coupon(coupon_code) do
      {:ok, %{discount_type: :percentage, value: pct}} ->
        discount = Decimal.mult(invoice.subtotal, Decimal.from_float(pct / 100.0))
        updated = Invoice.changeset(invoice, %{discount: discount})
        Repo.update(updated)

      {:ok, %{discount_type: :fixed, value: amount}} ->
        discount = Decimal.min(Decimal.new(amount), invoice.subtotal)
        updated = Invoice.changeset(invoice, %{discount: discount})
        Repo.update(updated)

      {:error, :not_found} ->
        {:error, :invalid_coupon}
    end
  end

  defp fetch_coupon(code) do
    case Repo.get_by(Billing.Coupon, code: code, active: true) do
      nil -> {:error, :not_found}
      coupon -> {:ok, coupon}
    end
  end


  def send_invoice_email(invoice, user) do
    body = """
    Hello #{user.name},

    Your invoice ##{invoice.id} for #{invoice.subtotal} is due on
    #{Calendar.strftime(invoice.due_at, "%Y-%m-%d")}.

    Please log in to your account to complete payment.
    """

    case Mailer.deliver(%{
           to: user.email,
           subject: "Invoice ##{invoice.id} — Payment Due",
           text_body: body
         }) do
      {:ok, _} ->
        Logger.info("Invoice email sent to #{user.email}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to send invoice email: #{inspect(reason)}")
        {:error, reason}
    end
  end


  def generate_pdf(%Invoice{} = invoice) do
    template = File.read!("priv/templates/invoice.html.eex")

    rendered =
      EEx.eval_string(template,
        invoice_id: invoice.id,
        subtotal: invoice.subtotal,
        tax: invoice.tax,
        total: invoice.total,
        issued_at: invoice.issued_at,
        due_at: invoice.due_at
      )

    pdf_path = "/tmp/invoice_#{invoice.id}.pdf"

    case ChromicPDF.print_to_pdf({:html, rendered}, output: pdf_path) do
      :ok -> {:ok, pdf_path}
      error -> {:error, error}
    end
  end


  def record_payment(invoice, payment_params) do
    attrs = Map.merge(payment_params, %{invoice_id: invoice.id, recorded_at: DateTime.utc_now()})

    with {:ok, payment} <- Repo.insert(Payment.changeset(%Payment{}, attrs)),
         {:ok, _invoice} <-
           Repo.update(Invoice.changeset(invoice, %{status: :paid, paid_at: DateTime.utc_now()})) do
      Logger.info("Payment #{payment.id} recorded for invoice #{invoice.id}")
      {:ok, payment}
    else
      {:error, reason} ->
        Logger.error("Failed to record payment: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def refund_payment(%Payment{} = payment) do
    with {:ok, _} <-
           ExPayments.refund(payment.gateway_transaction_id, payment.amount),
         {:ok, updated} <-
           Repo.update(Payment.changeset(payment, %{status: :refunded, refunded_at: DateTime.utc_now()})) do
      Logger.info("Payment #{payment.id} refunded successfully")
      {:ok, updated}
    else
      {:error, reason} ->
        Logger.error("Refund failed for payment #{payment.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
```
