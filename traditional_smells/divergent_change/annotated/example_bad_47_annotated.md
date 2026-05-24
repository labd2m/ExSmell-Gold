# Annotated Example — Code Smell Validation

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** The entire `PaymentGateway` module
- **Affected function(s):** `charge/3`, `refund/2`, `capture_preauthorised/2`, `assess_fraud_risk/2`, `flag_transaction/2`, `generate_invoice/2`, `mark_invoice_paid/2`
- **Short explanation:** The `PaymentGateway` module owns three completely unrelated responsibilities: payment processing (charge, refund, capture), fraud detection (risk scoring, flagging), and invoice management (generation, status updates). A change in payment provider API, a change in fraud-scoring rules, or a change in invoice numbering conventions would each independently require edits to this module — the defining symptom of Divergent Change.

---

```elixir
defmodule MyApp.PaymentGateway do
  @moduledoc """
  Processes payments, evaluates fraud risk on transactions,
  and manages the full invoice lifecycle.
  """

  alias MyApp.Repo
  alias MyApp.Billing.{Transaction, Invoice}
  alias MyApp.Customers.Customer
  import Ecto.Query

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because three completely different concerns coexist
  # VALIDATION: in one module. Payment processing functions change when the payment
  # VALIDATION: provider API changes. Fraud detection functions change when risk models
  # VALIDATION: or rule thresholds change. Invoice functions change when accounting
  # VALIDATION: requirements or numbering schemes change. These are independent reasons
  # VALIDATION: to modify the module, making it a Divergent Change.

  # ── Reason to modify (1): Payment processing ───────────────────────────────

  @provider_url "https://payments.provider.io/v2"

  def charge(customer_id, amount_cents, opts \\ []) do
    customer = Repo.get!(Customer, customer_id)
    idempotency_key = Keyword.get(opts, :idempotency_key, generate_key())
    currency = Keyword.get(opts, :currency, "USD")

    payload = %{
      amount: amount_cents,
      currency: currency,
      customer_ref: customer.external_payment_id,
      idempotency_key: idempotency_key
    }

    with {:ok, response} <- post_to_provider("/charges", payload),
         {:ok, txn} <- persist_transaction(customer_id, response, :charge) do
      {:ok, txn}
    end
  end

  def refund(transaction_id, amount_cents) do
    txn = Repo.get!(Transaction, transaction_id)

    if txn.status != :settled do
      {:error, :not_refundable}
    else
      payload = %{
        provider_charge_id: txn.provider_reference,
        amount: amount_cents
      }

      with {:ok, response} <- post_to_provider("/refunds", payload) do
        txn
        |> Transaction.changeset(%{
          status: :refunded,
          refund_provider_reference: response["id"],
          refunded_at: DateTime.utc_now()
        })
        |> Repo.update()
      end
    end
  end

  def capture_preauthorised(transaction_id, final_amount_cents) do
    txn = Repo.get!(Transaction, transaction_id)

    if txn.status != :authorised do
      {:error, :not_capturable}
    else
      payload = %{
        provider_auth_id: txn.provider_reference,
        amount: final_amount_cents
      }

      with {:ok, response} <- post_to_provider("/captures", payload) do
        txn
        |> Transaction.changeset(%{
          status: :settled,
          amount_cents: final_amount_cents,
          settled_at: DateTime.utc_now(),
          provider_reference: response["id"]
        })
        |> Repo.update()
      end
    end
  end

  defp post_to_provider(path, payload) do
    MyApp.HTTPClient.post(@provider_url <> path, payload,
      headers: [{"Authorization", "Bearer #{provider_api_key()}"}]
    )
  end

  defp persist_transaction(customer_id, response, type) do
    %Transaction{}
    |> Transaction.changeset(%{
      customer_id: customer_id,
      provider_reference: response["id"],
      amount_cents: response["amount"],
      currency: response["currency"],
      status: :settled,
      type: type
    })
    |> Repo.insert()
  end

  defp generate_key, do: :crypto.strong_rand_bytes(16) |> Base.hex_encode32(case: :lower)
  defp provider_api_key, do: Application.fetch_env!(:my_app, :payment_provider_api_key)

  # ── Reason to modify (2): Fraud detection & risk scoring ───────────────────

  @high_risk_threshold 75
  @velocity_window_minutes 30
  @max_charges_per_window 5

  def assess_fraud_risk(customer_id, amount_cents) do
    score = compute_risk_score(customer_id, amount_cents)

    risk_level =
      cond do
        score >= @high_risk_threshold -> :high
        score >= 40 -> :medium
        true -> :low
      end

    {:ok, %{score: score, risk_level: risk_level}}
  end

  def flag_transaction(transaction_id, reason) do
    transaction_id
    |> Repo.get!(Transaction)
    |> Transaction.changeset(%{
      flagged: true,
      flag_reason: reason,
      flagged_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  defp compute_risk_score(customer_id, amount_cents) do
    window_start = DateTime.add(DateTime.utc_now(), -@velocity_window_minutes * 60, :second)

    recent_count =
      from(t in Transaction,
        where: t.customer_id == ^customer_id and t.inserted_at >= ^window_start,
        select: count(t.id)
      )
      |> Repo.one()

    velocity_score = min(recent_count / @max_charges_per_window * 50, 50)
    amount_score = if amount_cents > 50_000, do: 30, else: 0

    round(velocity_score + amount_score)
  end

  # ── Reason to modify (3): Invoice generation & lifecycle ───────────────────

  @invoice_prefix "INV"

  def generate_invoice(customer_id, line_items) when is_list(line_items) do
    subtotal = Enum.sum(Enum.map(line_items, &(&1.qty * &1.unit_price_cents)))
    tax = round(subtotal * 0.2)
    total = subtotal + tax
    number = next_invoice_number()

    %Invoice{}
    |> Invoice.changeset(%{
      number: number,
      customer_id: customer_id,
      line_items: line_items,
      subtotal_cents: subtotal,
      tax_cents: tax,
      total_cents: total,
      status: :draft,
      due_date: Date.add(Date.utc_today(), 30)
    })
    |> Repo.insert()
  end

  def mark_invoice_paid(invoice_id, transaction_id) do
    invoice = Repo.get!(Invoice, invoice_id)

    invoice
    |> Invoice.changeset(%{
      status: :paid,
      paid_at: DateTime.utc_now(),
      payment_transaction_id: transaction_id
    })
    |> Repo.update()
  end

  defp next_invoice_number do
    last =
      from(i in Invoice, select: i.number, order_by: [desc: i.id], limit: 1)
      |> Repo.one()

    seq =
      case last do
        nil -> 1
        num -> num |> String.replace("#{@invoice_prefix}-", "") |> String.to_integer() |> Kernel.+(1)
      end

    "#{@invoice_prefix}-#{String.pad_leading(to_string(seq), 6, "0")}"
  end

  # VALIDATION: SMELL END
end
```
