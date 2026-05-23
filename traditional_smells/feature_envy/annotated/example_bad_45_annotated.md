# Code Smell Example – Annotated

- **Smell:** Feature Envy
- **Expected smell location:** `Payments.ReceiptBuilder.build_charge_summary/1`
- **Affected function(s):** `build_charge_summary/1`
- **Explanation:** `build_charge_summary/1` calls `ChargeRecord.get_payment_method/1`, `ChargeRecord.get_billing_address/1`, `ChargeRecord.list_fee_lines/1`, `ChargeRecord.refund_total/1`, and `ChargeRecord.dispute_status/1`, while reading multiple fields from the charge struct directly. `ReceiptBuilder` provides only formatting utilities. The function envies `ChargeRecord` and should live there.

```elixir
defmodule Payments.ReceiptBuilder do
  @moduledoc """
  Builds customer-facing payment receipts for successful charges,
  partial captures, and refund confirmations. Receipts are rendered
  as HTML and stored as PDF attachments in the document vault.
  """

  alias Payments.{ChargeRecord, PaymentMethod, BillingAddress}
  alias Payments.ReceiptBuilder.{Template, VaultStorage}

  @receipt_version "2.1"
  @vat_label       "VAT"

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @doc """
  Generates and stores a receipt PDF for the given charge ID.
  Returns `{:ok, receipt_url}` or `{:error, reason}`.
  """
  @spec generate(String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate(charge_id) do
    with {:ok, charge}  <- ChargeRecord.fetch(charge_id),
         :succeeded     <- charge.status,
         summary        <- build_charge_summary(charge),
         {:ok, html}    <- Template.render("receipt", summary),
         {:ok, pdf}     <- Template.html_to_pdf(html),
         {:ok, url}     <- VaultStorage.store(charge_id, pdf) do
      {:ok, url}
    else
      status when is_atom(status) -> {:error, {:unexpected_status, status}}
      error                       -> error
    end
  end

  @doc """
  Returns a plain-text receipt preview suitable for email body inclusion.
  """
  @spec text_preview(String.t()) :: {:ok, String.t()} | {:error, term()}
  def text_preview(charge_id) do
    with {:ok, charge} <- ChargeRecord.fetch(charge_id),
         summary       <- build_charge_summary(charge) do
      {:ok, Template.render_text("receipt_plain", summary)}
    end
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  # VALIDATION: SMELL START - Feature Envy
  # VALIDATION: This is a smell because build_charge_summary/1 is defined in
  # VALIDATION: ReceiptBuilder but almost all of its work is done through
  # VALIDATION: ChargeRecord's data and functions. It calls:
  # VALIDATION:   - ChargeRecord.get_payment_method/1
  # VALIDATION:   - ChargeRecord.get_billing_address/1
  # VALIDATION:   - ChargeRecord.list_fee_lines/1
  # VALIDATION:   - ChargeRecord.refund_total/1
  # VALIDATION:   - ChargeRecord.dispute_status/1
  # VALIDATION: and reads charge.id, charge.amount, charge.currency,
  # VALIDATION: charge.captured_at, charge.statement_descriptor,
  # VALIDATION: charge.metadata directly.
  # VALIDATION: ReceiptBuilder contributes only formatting helpers.
  # VALIDATION: The function should live inside ChargeRecord.
  defp build_charge_summary(charge) do
    payment_method  = ChargeRecord.get_payment_method(charge)
    billing_address = ChargeRecord.get_billing_address(charge)
    fee_lines       = ChargeRecord.list_fee_lines(charge)
    refund_total    = ChargeRecord.refund_total(charge)
    dispute         = ChargeRecord.dispute_status(charge)

    net_amount = Decimal.sub(charge.amount, refund_total)

    fees_map =
      Enum.map(fee_lines, fn fee ->
        %{label: fee.description, amount: format_money(fee.amount, charge.currency)}
      end)

    %{
      receipt_version:      @receipt_version,
      charge_id:            charge.id,
      captured_at:          format_datetime(charge.captured_at),
      statement_descriptor: charge.statement_descriptor,
      amount:               format_money(charge.amount, charge.currency),
      currency:             String.upcase(charge.currency),
      refund_total:         format_money(refund_total, charge.currency),
      net_amount:           format_money(net_amount, charge.currency),
      fee_lines:            fees_map,
      payment_method_label: PaymentMethod.masked_label(payment_method),
      payment_method_type:  payment_method.type,
      billing_name:         BillingAddress.full_name(billing_address),
      billing_address_line: BillingAddress.single_line(billing_address),
      dispute_status:       dispute,
      order_ref:            Map.get(charge.metadata, "order_id"),
      vat_label:            vat_label_for(charge.currency)
    }
  end
  # VALIDATION: SMELL END

  defp format_money(%Decimal{} = amount, currency) do
    symbol  = currency_symbol(currency)
    rounded = Decimal.round(amount, 2)
    "#{symbol}#{Decimal.to_string(rounded, :normal)}"
  end

  defp format_datetime(nil), do: ""
  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%B %d, %Y at %H:%M UTC")
  end

  defp currency_symbol("usd"), do: "$"
  defp currency_symbol("eur"), do: "€"
  defp currency_symbol("gbp"), do: "£"
  defp currency_symbol("brl"), do: "R$"
  defp currency_symbol(_),     do: ""

  defp vat_label_for(currency) when currency in ["eur", "gbp"], do: @vat_label
  defp vat_label_for(_), do: "Tax"
end
```
