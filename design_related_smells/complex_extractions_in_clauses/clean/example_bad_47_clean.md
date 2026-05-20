```elixir
defmodule Billing.InvoiceProcessor do
  @moduledoc """
  Handles invoice state transitions and financial computations
  within the billing processing pipeline.
  """

  require Logger

  alias Billing.{AuditLog, Mailer, NotificationQueue}

  @large_invoice_threshold 10_000.00
  @overdue_penalty_rate 0.05
  @overdue_grace_period_days 30

  defmodule Invoice do
    @moduledoc false
    defstruct [
      :id,
      :account_id,
      :account_name,
      :account_tier,
      :amount,
      :currency,
      :discount_rate,
      :tax_rate,
      :status,
      :due_date,
      :issued_at,
      :notes,
      :contact_email
    ]
  end

  @doc """
  Processes an invoice based on its current status and monetary amount.
  Returns a tagged tuple describing the processing outcome.
  """

  def process_invoice(%Invoice{
        id: id,
        account_id: account_id,
        account_name: account_name,
        account_tier: account_tier,
        amount: amount,
        currency: currency,
        discount_rate: discount_rate,
        tax_rate: tax_rate,
        status: status,
        due_date: _due_date,
        issued_at: issued_at,
        notes: notes,
        contact_email: contact_email
      })
      when status == :pending and amount >= @large_invoice_threshold do
    net_amount = calculate_net(amount, discount_rate, tax_rate)

    Logger.info("Large invoice #{id} for account #{account_name} flagged for manual approval")

    AuditLog.record(%{
      event: :large_invoice_flagged,
      invoice_id: id,
      account_id: account_id,
      account_tier: account_tier,
      net_amount: net_amount,
      currency: currency,
      issued_at: issued_at
    })

    Mailer.send_approval_request(contact_email, %{
      invoice_id: id,
      account_name: account_name,
      net_amount: net_amount,
      currency: currency
    })

    {:requires_approval,
     %{invoice_id: id, account_name: account_name, net_amount: net_amount, notes: notes}}
  end

  def process_invoice(%Invoice{
        id: id,
        account_id: account_id,
        account_name: account_name,
        account_tier: account_tier,
        amount: amount,
        currency: currency,
        discount_rate: discount_rate,
        tax_rate: tax_rate,
        status: status,
        due_date: _due_date,
        issued_at: issued_at,
        notes: notes,
        contact_email: contact_email
      })
      when status == :pending and amount < @large_invoice_threshold do
    net_amount = calculate_net(amount, discount_rate, tax_rate)

    Logger.info("Auto-approving standard invoice #{id} for account #{account_name}")

    AuditLog.record(%{
      event: :invoice_auto_approved,
      invoice_id: id,
      account_id: account_id,
      account_tier: account_tier,
      issued_at: issued_at
    })

    NotificationQueue.push(:invoice_approved, %{
      contact_email: contact_email,
      invoice_id: id,
      net_amount: net_amount,
      currency: currency
    })

    {:auto_approved,
     %{invoice_id: id, account_name: account_name, net_amount: net_amount, notes: notes}}
  end

  def process_invoice(%Invoice{
        id: id,
        account_id: account_id,
        account_name: account_name,
        account_tier: account_tier,
        amount: amount,
        currency: currency,
        discount_rate: discount_rate,
        tax_rate: tax_rate,
        status: status,
        due_date: due_date,
        issued_at: issued_at,
        notes: notes,
        contact_email: contact_email
      })
      when status == :overdue do
    net_amount = calculate_net(amount, discount_rate, tax_rate)
    days_overdue = Date.diff(Date.utc_today(), due_date)

    penalty =
      if days_overdue > @overdue_grace_period_days,
        do: net_amount * @overdue_penalty_rate,
        else: 0.0

    Logger.warning("Invoice #{id} overdue by #{days_overdue} days — account: #{account_name}")

    AuditLog.record(%{
      event: :invoice_overdue,
      invoice_id: id,
      account_id: account_id,
      account_tier: account_tier,
      days_overdue: days_overdue,
      issued_at: issued_at
    })

    Mailer.send_overdue_notice(contact_email, %{
      invoice_id: id,
      account_name: account_name,
      net_amount: net_amount,
      penalty: penalty,
      due_date: due_date,
      currency: currency
    })

    {:overdue,
     %{
       invoice_id: id,
       account_name: account_name,
       net_amount: net_amount,
       penalty: penalty,
       currency: currency,
       notes: notes,
       days_overdue: days_overdue
     }}
  end


  def process_invoice(%Invoice{id: id, status: status, account_name: account_name})
      when status in [:paid, :cancelled, :voided] do
    Logger.info("Invoice #{id} for #{account_name} is in terminal state: #{status}")
    {:no_action, %{invoice_id: id, status: status}}
  end

  defp calculate_net(amount, discount_rate, tax_rate) do
    amount
    |> Kernel.*(1 - discount_rate)
    |> Kernel.*(1 + tax_rate)
    |> Float.round(2)
  end
end
```
