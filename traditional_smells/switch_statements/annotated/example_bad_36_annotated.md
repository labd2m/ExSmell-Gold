# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `InvoiceWorkflow.status_display/1` and `InvoiceWorkflow.allowed_transitions/1`
- **Affected functions:** `status_display/1`, `allowed_transitions/1`
- **Short explanation:** The same `case` branching over invoice status (`:draft`, `:pending`, `:paid`, `:overdue`, `:cancelled`, `:disputed`) is duplicated in `status_display/1` and `allowed_transitions/1`. Adding a new status atom requires updating both case expressions.

---

```elixir
defmodule InvoiceWorkflow do
  @moduledoc """
  Manages the lifecycle of invoices from draft creation through
  payment, overdue escalation, dispute handling, and cancellation
  in a B2B billing platform.
  """

  alias InvoiceWorkflow.{Invoice, Customer, AuditTrail, NotificationService}

  @type invoice_status :: :draft | :pending | :paid | :overdue | :cancelled | :disputed

  @spec transition(Invoice.t(), invoice_status()) ::
          {:ok, Invoice.t()} | {:error, String.t()}
  def transition(%Invoice{} = invoice, new_status) do
    permitted = allowed_transitions(invoice.status)

    if new_status in permitted do
      updated = %{invoice | status: new_status, updated_at: DateTime.utc_now()}
      AuditTrail.record(:status_changed, invoice.id, %{from: invoice.status, to: new_status})
      maybe_notify_customer(updated)
      {:ok, updated}
    else
      {:error,
       "transition from #{invoice.status} to #{new_status} is not permitted. " <>
         "Allowed: #{inspect(permitted)}"}
    end
  end

  @spec render_status_badge(Invoice.t()) :: map()
  def render_status_badge(%Invoice{status: status}) do
    %{label: status_display(status), css_class: status_css_class(status)}
  end

  @spec can_void?(Invoice.t()) :: boolean()
  def can_void?(%Invoice{status: status}) do
    :cancelled in allowed_transitions(status)
  end

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `status`
  # also appears in `allowed_transitions/1` below. Both enumerate all six
  # invoice statuses — adding a new one requires updating both functions.
  @spec status_display(invoice_status()) :: String.t()
  def status_display(status) do
    case status do
      :draft     -> "Draft"
      :pending   -> "Awaiting Payment"
      :paid      -> "Paid"
      :overdue   -> "Overdue"
      :cancelled -> "Cancelled"
      :disputed  -> "Under Dispute"
    end
  end
  # VALIDATION: SMELL END

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `status`
  # already appeared in `status_display/1` above. All six status atoms are
  # repeated, causing the state machine to be defined in two disconnected places.
  @spec allowed_transitions(invoice_status()) :: [invoice_status()]
  def allowed_transitions(status) do
    case status do
      :draft     -> [:pending, :cancelled]
      :pending   -> [:paid, :overdue, :cancelled, :disputed]
      :paid      -> []
      :overdue   -> [:paid, :disputed, :cancelled]
      :cancelled -> []
      :disputed  -> [:paid, :cancelled]
    end
  end
  # VALIDATION: SMELL END

  @spec status_css_class(invoice_status()) :: String.t()
  defp status_css_class(status) do
    case status do
      :draft     -> "badge-secondary"
      :pending   -> "badge-warning"
      :paid      -> "badge-success"
      :overdue   -> "badge-danger"
      :cancelled -> "badge-dark"
      :disputed  -> "badge-info"
    end
  end

  @spec maybe_notify_customer(Invoice.t()) :: :ok
  defp maybe_notify_customer(%Invoice{status: :paid} = invoice) do
    NotificationService.send_receipt(invoice)
  end

  defp maybe_notify_customer(%Invoice{status: :overdue} = invoice) do
    NotificationService.send_overdue_reminder(invoice)
  end

  defp maybe_notify_customer(_invoice), do: :ok
end
```
