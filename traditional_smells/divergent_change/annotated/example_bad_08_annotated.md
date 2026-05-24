# Annotated Example — Divergent Change

| Field | Value |
|---|---|
| **Smell name** | Divergent Change |
| **Expected smell location** | `CustomerService` module |
| **Affected functions** | `register_customer/1`, `update_contact_info/2`, `deactivate_customer/1` (CRM reason) and `add_loyalty_points/2`, `redeem_points/2`, `get_loyalty_balance/1` (loyalty program reason) and `open_support_ticket/2`, `close_ticket/2`, `list_open_tickets/1` (support reason) |
| **Explanation** | The module handles customer CRM data, a loyalty/rewards program, and a support ticketing system — three completely independent concerns. Changes to the loyalty point rules, to the CRM data model, or to the support ticket workflow would each independently motivate changes to this single module. |

```elixir
defmodule CRM.CustomerService do
  @moduledoc """
  Manages customer records, loyalty point balances, and support tickets.
  """

  alias CRM.Repo
  alias CRM.Customers.Customer
  alias CRM.Loyalty.PointTransaction
  alias CRM.Support.Ticket

  import Ecto.Query
  require Logger

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module bundles three unrelated
  # concerns: (1) CRM and contact data management, (2) loyalty program point
  # tracking and redemption, and (3) support ticket lifecycle. Each concern
  # belongs to a different subdomain and has an independent reason to change.

  ## ── CRM / Contact Management ─────────────────────────────────────────────────

  @doc "Registers a new customer in the platform."
  @spec register_customer(map()) :: {:ok, Customer.t()} | {:error, Ecto.Changeset.t()}
  def register_customer(attrs) do
    %Customer{}
    |> Customer.changeset(Map.merge(attrs, %{status: :active, joined_at: DateTime.utc_now()}))
    |> Repo.insert()
  end

  @doc "Updates the customer's contact information (name, phone, address)."
  @spec update_contact_info(Customer.t(), map()) ::
          {:ok, Customer.t()} | {:error, Ecto.Changeset.t()}
  def update_contact_info(%Customer{} = customer, attrs) do
    allowed = Map.take(attrs, [:full_name, :phone, :shipping_address, :billing_address])

    customer
    |> Customer.changeset(allowed)
    |> Repo.update()
  end

  @doc "Deactivates a customer account, preventing further logins or purchases."
  @spec deactivate_customer(Customer.t()) ::
          {:ok, Customer.t()} | {:error, Ecto.Changeset.t()}
  def deactivate_customer(%Customer{} = customer) do
    customer
    |> Customer.changeset(%{status: :inactive, deactivated_at: DateTime.utc_now()})
    |> Repo.update()
  end

  ## ── Loyalty Program ───────────────────────────────────────────────────────────

  @doc "Credits loyalty points to a customer's account following a qualifying event."
  @spec add_loyalty_points(Customer.t(), map()) ::
          {:ok, PointTransaction.t()} | {:error, Ecto.Changeset.t()}
  def add_loyalty_points(%Customer{id: cid}, %{points: points, reason: reason}) do
    attrs = %{
      customer_id: cid,
      delta: points,
      transaction_type: :credit,
      reason: reason,
      recorded_at: DateTime.utc_now()
    }

    %PointTransaction{}
    |> PointTransaction.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Redeems loyalty points for a discount, validating that balance is sufficient."
  @spec redeem_points(Customer.t(), pos_integer()) ::
          {:ok, PointTransaction.t()} | {:error, atom()}
  def redeem_points(%Customer{id: cid}, points_to_redeem) do
    balance = get_loyalty_balance(%Customer{id: cid})

    if balance >= points_to_redeem do
      attrs = %{
        customer_id: cid,
        delta: -points_to_redeem,
        transaction_type: :debit,
        reason: "Points redeemed at checkout",
        recorded_at: DateTime.utc_now()
      }

      %PointTransaction{}
      |> PointTransaction.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, txn} -> {:ok, txn}
        error -> error
      end
    else
      {:error, :insufficient_points}
    end
  end

  @doc "Returns the current loyalty point balance for a customer."
  @spec get_loyalty_balance(Customer.t()) :: integer()
  def get_loyalty_balance(%Customer{id: cid}) do
    PointTransaction
    |> where([p], p.customer_id == ^cid)
    |> select([p], sum(p.delta))
    |> Repo.one()
    |> Kernel.||(0)
  end

  ## ── Support Ticketing ────────────────────────────────────────────────────────

  @doc "Opens a new support ticket on behalf of a customer."
  @spec open_support_ticket(Customer.t(), map()) ::
          {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  def open_support_ticket(%Customer{id: cid}, %{subject: subject, body: body, priority: priority}) do
    attrs = %{
      customer_id: cid,
      subject: subject,
      body: body,
      priority: priority,
      status: :open,
      opened_at: DateTime.utc_now()
    }

    %Ticket{}
    |> Ticket.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Closes a resolved support ticket and records a resolution note."
  @spec close_ticket(Ticket.t(), String.t()) ::
          {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  def close_ticket(%Ticket{status: :open} = ticket, resolution_note) do
    ticket
    |> Ticket.changeset(%{
      status: :closed,
      resolution_note: resolution_note,
      closed_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  def close_ticket(%Ticket{}, _), do: {:error, :ticket_not_open}

  @doc "Lists all open tickets for a customer, ordered by priority."
  @spec list_open_tickets(Customer.t()) :: [Ticket.t()]
  def list_open_tickets(%Customer{id: cid}) do
    priority_order = ~w(critical high medium low)a

    Ticket
    |> where([t], t.customer_id == ^cid and t.status == :open)
    |> Repo.all()
    |> Enum.sort_by(&Enum.find_index(priority_order, fn p -> p == &1.priority end))
  end

  # VALIDATION: SMELL END
end
```
