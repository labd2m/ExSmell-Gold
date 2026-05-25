```elixir
defmodule InvoiceStateMachine do
  @moduledoc """
  Manages invoice lifecycle state transitions, dunning process routing,
  customer portal action sets, and fee applicability rules for the
  billing engine.
  """

  require Logger

  @statuses [:draft, :open, :overdue, :paid, :voided]

  def valid_statuses, do: @statuses







  @doc """
  Returns true when a late payment fee may be applied to the invoice based
  on its current status.
  """
  def overdue_fee_applicable?(%{status: status}) do
    case status do
      :draft -> false
      :open -> false
      :overdue -> true
      :paid -> false
      :voided -> false
      _ -> false
    end
  end

  @doc """
  Returns the list of actions that should be presented to the customer on the
  self-service billing portal for the invoice's current status.
  """
  def customer_portal_actions(%{status: status}) do
    case status do
      :draft ->
        []

      :open ->
        [:pay_now, :download_pdf, :dispute]

      :overdue ->
        [:pay_now, :download_pdf, :request_payment_plan, :dispute]

      :paid ->
        [:download_pdf, :download_receipt]

      :voided ->
        [:download_pdf]

      _ ->
        [:download_pdf]
    end
  end

  @doc """
  Returns the dunning step identifier for an invoice. Controls which automated
  follow-up email sequence is triggered by the collections job.
  """
  def dunning_step(%{status: status}) do
    case status do
      :draft -> :none
      :open -> :reminder_1
      :overdue -> :escalation
      :paid -> :none
      :voided -> :none
      _ -> :none
    end
  end



  @doc """
  Computes the allowed status transitions from the current invoice status.
  """
  def allowed_transitions(%{status: status}) do
    case status do
      :draft -> [:open, :voided]
      :open -> [:paid, :overdue, :voided]
      :overdue -> [:paid, :voided]
      :paid -> []
      :voided -> []
      _ -> []
    end
  end

  @doc """
  Attempts a status transition, enforcing allowed transition rules.
  """
  def transition(%{status: current} = invoice, new_status) do
    allowed = allowed_transitions(invoice)

    if new_status in allowed do
      updated =
        invoice
        |> Map.put(:status, new_status)
        |> Map.put(:status_changed_at, DateTime.utc_now())

      Logger.info("Invoice #{invoice.id} transitioned: #{current} -> #{new_status}.")
      {:ok, updated}
    else
      Logger.warning(
        "Blocked invalid invoice transition: #{current} -> #{new_status} for #{invoice.id}."
      )

      {:error, {:invalid_transition, {current, new_status}}}
    end
  end

  @doc """
  Marks open invoices as overdue when their due date has passed.
  Returns `{:ok, updated_invoice}` or `{:ok, :no_action_required}`.
  """
  def maybe_mark_overdue(%{status: :open, due_date: due_date} = invoice) do
    if Date.compare(due_date, Date.utc_today()) == :lt do
      transition(invoice, :overdue)
    else
      {:ok, :no_action_required}
    end
  end

  def maybe_mark_overdue(invoice), do: {:ok, :no_action_required}

  @doc """
  Calculates the late fee amount in cents for an overdue invoice.
  Returns 0 when fees are not applicable.
  """
  def late_fee_cents(%{} = invoice, fee_rate \\ 0.015) do
    if overdue_fee_applicable?(invoice) do
      trunc(invoice.total_cents * fee_rate)
    else
      0
    end
  end

  @doc """
  Builds the full invoice status context map consumed by the billing portal API.
  """
  def status_context(%{} = invoice) do
    fee = late_fee_cents(invoice)

    %{
      id: invoice.id,
      status: invoice.status,
      actions: customer_portal_actions(invoice),
      dunning_step: dunning_step(invoice),
      late_fee_cents: fee,
      total_due_cents: invoice.total_cents + fee
    }
  end

  @doc """
  Processes a batch of invoices to identify and escalate those that have
  become overdue since the last collection run.
  """
  def run_overdue_sweep(invoices) when is_list(invoices) do
    results =
      Enum.map(invoices, fn invoice ->
        case maybe_mark_overdue(invoice) do
          {:ok, :no_action_required} -> {invoice.id, :skipped}
          {:ok, updated} -> {invoice.id, {:transitioned, updated.status}}
          {:error, reason} -> {invoice.id, {:error, reason}}
        end
      end)

    transitioned = Enum.count(results, fn {_, r} -> match?({:transitioned, _}, r) end)
    Logger.info("Overdue sweep complete. #{transitioned}/#{length(invoices)} invoices escalated.")
    results
  end
end
```
