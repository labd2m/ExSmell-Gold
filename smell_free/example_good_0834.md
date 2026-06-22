```elixir
defmodule Billing.InvoiceStateMachine do
  @moduledoc """
  Pure functional state machine for invoice lifecycle transitions.
  Each valid transition produces both an updated invoice struct and a
  list of side-effect descriptors. Callers execute the side effects;
  the machine itself remains free of I/O, making it straightforward to
  test all business rules in isolation without mocking databases or mailers.
  """

  alias Billing.Invoice

  @type transition_result ::
          {:ok, Invoice.t(), [side_effect()]} | {:error, term()}

  @type side_effect ::
          {:send_email, atom(), map()}
          | {:publish_event, atom(), map()}
          | {:update_billing_record, map()}
          | {:notify_accounting, map()}

  # ---------------------------------------------------------------------------
  # Transitions
  # ---------------------------------------------------------------------------

  @doc """
  Transitions a draft invoice to `:open`, making it payable.
  """
  @spec finalise(Invoice.t()) :: transition_result()
  def finalise(%Invoice{status: :draft} = invoice) do
    updated = %Invoice{
      invoice
      | status: :open,
        finalised_at: utc_now(),
        due_at: DateTime.add(utc_now(), invoice.payment_terms_days * 86_400, :second)
    }

    effects = [
      {:send_email, :invoice_issued, %{invoice_id: invoice.id, customer_id: invoice.customer_id}},
      {:publish_event, :invoice_finalised, invoice_payload(updated)},
      {:update_billing_record, %{invoice_id: invoice.id, status: :open}}
    ]

    {:ok, updated, effects}
  end

  def finalise(%Invoice{status: status}), do: {:error, {:invalid_transition, status, :open}}

  @doc """
  Records a payment against an open invoice. Marks it as `:paid` when
  the full balance is settled.
  """
  @spec pay(Invoice.t(), pos_integer()) :: transition_result()
  def pay(%Invoice{status: :open} = invoice, amount_cents)
      when is_integer(amount_cents) and amount_cents > 0 do
    new_paid = invoice.paid_cents + amount_cents
    status = if new_paid >= invoice.total_cents, do: :paid, else: :partially_paid

    updated = %Invoice{
      invoice
      | paid_cents: new_paid,
        status: status,
        paid_at: if(status == :paid, do: utc_now(), else: nil)
    }

    base_effects = [
      {:publish_event, :payment_received,
       %{invoice_id: invoice.id, amount_cents: amount_cents, remaining_cents: updated.total_cents - new_paid}}
    ]

    paid_effects =
      if status == :paid do
        [
          {:send_email, :receipt_issued, %{invoice_id: invoice.id, customer_id: invoice.customer_id}},
          {:notify_accounting, %{invoice_id: invoice.id, total_cents: invoice.total_cents}}
        ]
      else
        []
      end

    {:ok, updated, base_effects ++ paid_effects}
  end

  def pay(%Invoice{status: :partially_paid} = invoice, amount_cents) do
    pay(%Invoice{invoice | status: :open}, amount_cents)
  end

  def pay(%Invoice{status: status}, _amount), do: {:error, {:invalid_transition, status, :paid}}

  @doc """
  Voids an open or draft invoice. Paid invoices cannot be voided; they
  must be refunded instead.
  """
  @spec void(Invoice.t(), binary()) :: transition_result()
  def void(%Invoice{status: status} = invoice, reason)
      when status in [:draft, :open] and is_binary(reason) do
    updated = %Invoice{invoice | status: :void, voided_at: utc_now(), void_reason: reason}

    effects = [
      {:publish_event, :invoice_voided, %{invoice_id: invoice.id, reason: reason}},
      {:update_billing_record, %{invoice_id: invoice.id, status: :void}}
    ]

    {:ok, updated, effects}
  end

  def void(%Invoice{status: :paid}, _reason), do: {:error, :cannot_void_paid_invoice}
  def void(%Invoice{status: status}, _reason), do: {:error, {:invalid_transition, status, :void}}

  @doc """
  Marks an open invoice as overdue. No side effects are triggered here;
  the caller should handle dunning logic separately.
  """
  @spec mark_overdue(Invoice.t()) :: transition_result()
  def mark_overdue(%Invoice{status: :open} = invoice) do
    updated = %Invoice{invoice | status: :overdue}

    effects = [
      {:publish_event, :invoice_overdue,
       %{invoice_id: invoice.id, due_at: invoice.due_at, customer_id: invoice.customer_id}}
    ]

    {:ok, updated, effects}
  end

  def mark_overdue(%Invoice{status: status}), do: {:error, {:invalid_transition, status, :overdue}}

  @doc """
  Returns all valid next statuses from the given current status.
  """
  @spec reachable_statuses(Invoice.status()) :: [Invoice.status()]
  def reachable_statuses(:draft), do: [:open, :void]
  def reachable_statuses(:open), do: [:partially_paid, :paid, :overdue, :void]
  def reachable_statuses(:partially_paid), do: [:paid, :overdue]
  def reachable_statuses(:overdue), do: [:paid]
  def reachable_statuses(:paid), do: []
  def reachable_statuses(:void), do: []

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp invoice_payload(%Invoice{} = inv) do
    %{
      invoice_id: inv.id,
      customer_id: inv.customer_id,
      total_cents: inv.total_cents,
      currency: inv.currency,
      status: inv.status
    }
  end

  defp utc_now, do: DateTime.utc_now()
end
```
