```elixir
defmodule Billing.Workers.InvoiceGenerator do
  @moduledoc """
  An Oban worker that generates monthly invoices for all subscriptions
  whose billing cycle closes on the current calendar day. Each subscription
  is processed in its own job execution so a single failure is isolated and
  retried independently without blocking the rest of the batch.
  This worker is enqueued by a cron-style Oban scheduler entry defined in
  the application config. It acts as a fan-out dispatcher, not a bulk processor.
  """

  use Oban.Worker,
    queue: :billing,
    max_attempts: 3,
    unique: [period: 86_400, fields: [:worker, :args]]

  alias Billing.{Invoices, Subscriptions}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => subscription_id}}) do
    with {:ok, subscription} <- Subscriptions.fetch(subscription_id),
         :ok <- assert_billing_due(subscription),
         {:ok, invoice} <- Invoices.generate_for(subscription) do
      Logger.info("Invoice generated",
        subscription_id: subscription_id,
        invoice_id: invoice.id,
        amount_cents: invoice.total_cents
      )

      :ok
    else
      {:error, :billing_not_due} ->
        Logger.debug("Skipping invoice; billing not due", subscription_id: subscription_id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: %{"dispatch" => true}}) do
    today = Date.utc_today()
    subscriptions = Subscriptions.list_billing_due_on(today)

    Logger.info("Dispatching invoice jobs", count: length(subscriptions), billing_date: today)

    jobs =
      Enum.map(subscriptions, fn sub ->
        new(%{"subscription_id" => sub.id})
      end)

    Oban.insert_all(jobs)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp assert_billing_due(%{next_billing_date: date}) do
    if Date.compare(date, Date.utc_today()) == :eq do
      :ok
    else
      {:error, :billing_not_due}
    end
  end
end

defmodule Billing.Workers.InvoiceMailer do
  @moduledoc """
  An Oban worker that delivers a generated invoice to the customer via email.
  Enqueued automatically after successful invoice creation via an Oban
  callback in `Billing.Invoices`. Implements idempotency via Oban's unique
  constraint so duplicate deliveries are suppressed on retry.
  """

  use Oban.Worker,
    queue: :mailer,
    max_attempts: 5,
    unique: [period: 172_800, fields: [:worker, :args]]

  alias Billing.{Invoices, Mailer}
  alias MyAppWeb.Emails.InvoiceEmail

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"invoice_id" => invoice_id}}) do
    with {:ok, invoice} <- Invoices.fetch(invoice_id),
         {:ok, customer} <- Billing.Customers.fetch(invoice.customer_id),
         {:ok, _} <- deliver(invoice, customer) do
      Logger.info("Invoice email delivered",
        invoice_id: invoice_id,
        customer_id: customer.id,
        email: customer.email
      )

      :ok
    end
  end

  defp deliver(invoice, customer) do
    invoice
    |> InvoiceEmail.build(customer)
    |> Mailer.deliver()
  end
end
```
