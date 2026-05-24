# Annotated Example — Divergent Change

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** `CustomerService` module (entire module)
- **Affected functions:** `register_customer/1`, `update_profile/2`, `open_support_ticket/3`, `escalate_ticket/2`, `charge_customer/3`, `refund_customer/3`
- **Short explanation:** `CustomerService` merges CRM/profile management, support-ticket workflows, and billing operations into one module. Each concern has its own evolution lifecycle (GDPR changes affect profiles, SLA policies affect tickets, payment-provider changes affect billing), forcing unrelated edits to a single module.

---

```elixir
defmodule CRM.CustomerService do
  @moduledoc """
  Manages customer profiles, support interactions, and billing transactions.
  """

  require Logger

  alias CRM.Repo
  alias CRM.Customers.Customer
  alias CRM.Support.Ticket
  alias CRM.Billing.Transaction

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module unifies three unrelated
  # responsibilities: (1) CRM/profile management, (2) support-ticket workflow,
  # and (3) billing/payments. Each area will change for completely different
  # reasons — compliance rules, SLA updates, or payment provider changes.

  ## ─────────────────────────────────────────────
  ## Reason to modify (1): CRM / profile management
  ## ─────────────────────────────────────────────

  @doc "Registers a new customer in the system."
  def register_customer(attrs) do
    changeset =
      Customer.changeset(%Customer{}, Map.put(attrs, :registered_at, DateTime.utc_now()))

    case Repo.insert(changeset) do
      {:ok, customer} ->
        Logger.info("Customer registered: #{customer.email}")
        {:ok, customer}

      {:error, cs} ->
        {:error, cs}
    end
  end

  @doc "Updates a customer's profile data."
  def update_profile(%Customer{} = customer, attrs) do
    allowed = [:name, :phone, :address, :preferences, :communication_opt_in]
    filtered = Map.take(attrs, allowed)

    customer
    |> Customer.changeset(filtered)
    |> Repo.update()
  end

  @doc "Returns a GDPR-compliant data export for a customer."
  def export_customer_data(%Customer{} = customer) do
    %{
      id: customer.id,
      name: customer.name,
      email: customer.email,
      registered_at: customer.registered_at,
      preferences: customer.preferences
    }
  end

  ## ─────────────────────────────────────────────
  ## Reason to modify (2): Support-ticket workflow
  ## ─────────────────────────────────────────────

  @doc "Opens a new support ticket on behalf of a customer."
  def open_support_ticket(%Customer{} = customer, category, description) do
    changeset =
      Ticket.changeset(%Ticket{}, %{
        customer_id: customer.id,
        category: category,
        description: description,
        status: :open,
        priority: default_priority(category),
        opened_at: DateTime.utc_now()
      })

    case Repo.insert(changeset) do
      {:ok, ticket} ->
        Logger.info("Ticket #{ticket.id} opened for customer #{customer.id}")
        {:ok, ticket}

      {:error, cs} ->
        {:error, cs}
    end
  end

  @doc "Escalates an open ticket to a senior support agent."
  def escalate_ticket(%Ticket{status: :open} = ticket, reason) do
    ticket
    |> Ticket.changeset(%{
      priority: :high,
      escalation_reason: reason,
      escalated_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  def escalate_ticket(%Ticket{}, _reason), do: {:error, :ticket_not_open}

  ## ─────────────────────────────────────────────
  ## Reason to modify (3): Billing / payments
  ## ─────────────────────────────────────────────

  @doc "Charges a customer for a given product or service."
  def charge_customer(%Customer{} = customer, amount, description) do
    changeset =
      Transaction.changeset(%Transaction{}, %{
        customer_id: customer.id,
        amount: amount,
        currency: customer.preferred_currency || "USD",
        direction: :debit,
        description: description,
        status: :pending,
        initiated_at: DateTime.utc_now()
      })

    case Repo.insert(changeset) do
      {:ok, txn} ->
        Logger.info("Charged #{amount} to customer #{customer.id} (txn #{txn.id})")
        {:ok, txn}

      {:error, cs} ->
        {:error, cs}
    end
  end

  @doc "Issues a refund to a customer for a previous transaction."
  def refund_customer(%Customer{} = customer, original_txn_id, amount) do
    changeset =
      Transaction.changeset(%Transaction{}, %{
        customer_id: customer.id,
        reference_txn_id: original_txn_id,
        amount: amount,
        currency: customer.preferred_currency || "USD",
        direction: :credit,
        description: "Refund for txn #{original_txn_id}",
        status: :pending,
        initiated_at: DateTime.utc_now()
      })

    case Repo.insert(changeset) do
      {:ok, txn} ->
        Logger.info("Refund #{amount} issued to customer #{customer.id} (txn #{txn.id})")
        {:ok, txn}

      {:error, cs} ->
        {:error, cs}
    end
  end

  # VALIDATION: SMELL END

  ## ── Private helpers ──────────────────────

  defp default_priority(:billing), do: :high
  defp default_priority(:technical), do: :medium
  defp default_priority(_), do: :low
end
```
