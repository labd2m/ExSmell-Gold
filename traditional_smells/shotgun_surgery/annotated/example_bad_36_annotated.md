## Smell Metadata

- **Smell:** Shotgun Surgery
- **Expected Smell Location:** Functions `process/2`, `reversible?/1` in `Commerce.EventProcessor`; `log_level/1`, `include_in_feed?/1` in `Commerce.EventLogger`; `should_notify_customer?/1`, `notification_template/1` in `Commerce.EventNotifier`
- **Affected Functions:** See above (6 functions across 3 modules)
- **Explanation:** Adding a new commerce event type (e.g., `:dispute`) requires scattered changes across three separate event handling modules. Processing logic, logging verbosity, and customer notification rules are each independently defined per event type with no shared event type registry.

```elixir
defmodule Commerce.EventProcessor do
  @moduledoc """
  Handles incoming commerce lifecycle events, applying the appropriate
  financial and inventory side-effects for each event type.
  """

  # VALIDATION: SMELL START - Shotgun Surgery
  # VALIDATION: This is a smell because adding a new event type (e.g., :dispute)
  # VALIDATION: requires new clauses in process/2 and reversible?/1 here, AND
  # VALIDATION: independent changes in Commerce.EventLogger and Commerce.EventNotifier.

  @spec process(atom(), map()) :: {:ok, map()} | {:error, term()}
  def process(:purchase, event) do
    with :ok <- Inventory.deduct(event.order_id, event.line_items),
         {:ok, ledger_entry} <- Ledger.credit(:revenue, event.amount) do
      {:ok, %{order_id: event.order_id, ledger_ref: ledger_entry.id, status: :completed}}
    end
  end

  def process(:refund, event) do
    with :ok <- Inventory.restore(event.order_id, event.line_items),
         {:ok, ledger_entry} <- Ledger.debit(:revenue, event.amount),
         :ok <- Payments.GatewayAdapter.refund(event.gateway, %{
                  transaction_id: event.original_transaction_id,
                  amount_cents:   round(event.amount * 100)
                }) do
      {:ok, %{refund_id: event.id, ledger_ref: ledger_entry.id, status: :refunded}}
    end
  end

  def process(:chargeback, event) do
    with {:ok, ledger_entry} <- Ledger.debit(:revenue, event.amount),
         :ok <- Fraud.flag_account(event.customer_id, :chargeback) do
      {:ok, %{chargeback_id: event.id, ledger_ref: ledger_entry.id, status: :lost}}
    end
  end

  @spec reversible?(atom()) :: boolean()
  def reversible?(:purchase),   do: true
  def reversible?(:refund),     do: false
  def reversible?(:chargeback), do: false

  # VALIDATION: SMELL END
end

defmodule Commerce.EventLogger do
  @moduledoc """
  Records commerce events to structured logs and analytics pipelines,
  applying appropriate verbosity levels based on event severity.
  """

  # VALIDATION: SMELL START - Shotgun Surgery
  # VALIDATION: log_level/1 and include_in_feed?/1 require separate independent
  # VALIDATION: new clauses per event type.

  @spec log_level(atom()) :: atom()
  def log_level(:purchase),   do: :info
  def log_level(:refund),     do: :warning
  def log_level(:chargeback), do: :error

  @spec include_in_feed?(atom()) :: boolean()
  def include_in_feed?(:purchase),   do: true
  def include_in_feed?(:refund),     do: true
  def include_in_feed?(:chargeback), do: false

  # VALIDATION: SMELL END

  def log(event_type, event, result) do
    level = log_level(event_type)
    in_feed = include_in_feed?(event_type)

    entry = %{
      event_type: event_type,
      event_id:   event.id,
      customer:   event.customer_id,
      amount:     event.amount,
      result:     result,
      logged_at:  DateTime.utc_now()
    }

    Logger.log(level, "[Commerce.Event] #{event_type}", entry)

    if in_feed do
      Analytics.track("commerce_event", entry)
    end
  end
end

defmodule Commerce.EventNotifier do
  @moduledoc """
  Sends transactional notifications to customers and internal teams
  when commerce events occur, using event-appropriate templates.
  """

  # VALIDATION: SMELL START - Shotgun Surgery
  # VALIDATION: should_notify_customer?/1 and notification_template/1 must also be
  # VALIDATION: updated for each new event type independently.

  @spec should_notify_customer?(atom()) :: boolean()
  def should_notify_customer?(:purchase),   do: true
  def should_notify_customer?(:refund),     do: true
  def should_notify_customer?(:chargeback), do: false

  @spec notification_template(atom()) :: String.t()
  def notification_template(:purchase),   do: "emails/purchase_confirmation.html"
  def notification_template(:refund),     do: "emails/refund_processed.html"
  def notification_template(:chargeback), do: "emails/internal_chargeback_alert.html"

  # VALIDATION: SMELL END

  def notify(event_type, event) do
    if should_notify_customer?(event_type) do
      template = notification_template(event_type)
      Mailer.send_templated(event.customer.email, template, %{
        customer_name:  event.customer.full_name,
        order_id:       event.order_id,
        amount:         event.amount,
        currency:       event.currency,
        event_date:     event.occurred_at
      })
    end

    notify_internal(event_type, event)
  end

  defp notify_internal(:chargeback, event) do
    Slack.post("#finance-alerts",
      "⚠️ Chargeback received for order #{event.order_id} " <>
      "(customer: #{event.customer_id}, amount: #{event.amount})")
  end

  defp notify_internal(_, _), do: :ok
end
```
