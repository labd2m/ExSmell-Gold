# Annotated Example — Divergent Change

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** `CustomerHub` module (entire module)
- **Affected functions:** `register_customer/1`, `update_contact_info/2`, `award_loyalty_points/3`, `redeem_loyalty_points/2`, `open_support_ticket/3`, `close_support_ticket/2`
- **Explanation:** `CustomerHub` combines customer registration/profile updates, a loyalty points system, and a support ticketing system. These are three independent domains — profile rules evolve with compliance needs, loyalty policies change with marketing strategy, and support workflows change with operational tooling — making this module a clear Divergent Change.

---

```elixir
defmodule MyApp.CustomerHub do
  @moduledoc """
  Central module for customer management, loyalty rewards tracking,
  and support ticket lifecycle operations.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.{Customer, LoyaltyTransaction, SupportTicket}
  import Ecto.Query

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because customer profile management,
  # loyalty rewards, and support ticketing are three independent domains.
  # GDPR changes affect profile functions, marketing decisions affect
  # loyalty logic, and helpdesk tooling changes affect ticket workflows.
  # Each drives unrelated modifications to this single module.

  ## ── Customer Profile ────────────────────────────────────────────────────────

  @doc """
  Registers a new customer after validating uniqueness of email.
  """
  def register_customer(attrs) do
    email = attrs |> Map.get(:email, "") |> String.downcase() |> String.trim()

    if Repo.exists?(from c in Customer, where: c.email == ^email) do
      {:error, :email_taken}
    else
      %Customer{}
      |> Customer.changeset(Map.put(attrs, :email, email))
      |> Repo.insert()
    end
  end

  @doc """
  Updates mutable contact fields for an existing customer.
  """
  def update_contact_info(%Customer{} = customer, attrs) do
    allowed = [:phone, :address_line1, :address_line2, :city, :state, :postal_code, :country]
    filtered = Map.take(attrs, allowed)

    customer
    |> Customer.changeset(filtered)
    |> Repo.update()
  end

  @doc """
  Returns a customer by ID or nil if not found.
  """
  def get_customer(id) do
    Repo.get(Customer, id)
  end

  ## ── Loyalty Program ──────────────────────────────────────────────────────────

  @doc """
  Awards loyalty points to a customer for a given reason (e.g., purchase, referral).
  """
  def award_loyalty_points(%Customer{} = customer, points, reason) when points > 0 do
    Repo.transaction(fn ->
      %LoyaltyTransaction{}
      |> LoyaltyTransaction.changeset(%{
        customer_id: customer.id,
        type: :credit,
        points: points,
        reason: reason,
        transacted_at: DateTime.utc_now()
      })
      |> Repo.insert!()

      customer
      |> Customer.changeset(%{loyalty_points: customer.loyalty_points + points})
      |> Repo.update!()
    end)
  end

  @doc """
  Redeems loyalty points from a customer's balance.
  Returns an error if the balance is insufficient.
  """
  def redeem_loyalty_points(%Customer{} = customer, points) when points > 0 do
    if customer.loyalty_points < points do
      {:error, :insufficient_points}
    else
      Repo.transaction(fn ->
        %LoyaltyTransaction{}
        |> LoyaltyTransaction.changeset(%{
          customer_id: customer.id,
          type: :debit,
          points: points,
          reason: "redemption",
          transacted_at: DateTime.utc_now()
        })
        |> Repo.insert!()

        customer
        |> Customer.changeset(%{loyalty_points: customer.loyalty_points - points})
        |> Repo.update!()
      end)
    end
  end

  @doc """
  Returns the full loyalty transaction history for a customer.
  """
  def loyalty_history(%Customer{id: id}) do
    from(t in LoyaltyTransaction,
      where: t.customer_id == ^id,
      order_by: [desc: t.transacted_at]
    )
    |> Repo.all()
  end

  ## ── Support Tickets ──────────────────────────────────────────────────────────

  @doc """
  Opens a new support ticket for the given customer.
  """
  def open_support_ticket(%Customer{} = customer, subject, body) do
    %SupportTicket{}
    |> SupportTicket.changeset(%{
      customer_id: customer.id,
      subject: subject,
      body: body,
      status: :open,
      priority: classify_priority(subject),
      opened_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  @doc """
  Closes an open support ticket with a resolution note.
  """
  def close_support_ticket(%SupportTicket{status: :closed}, _note) do
    {:error, :already_closed}
  end

  def close_support_ticket(%SupportTicket{} = ticket, resolution_note) do
    ticket
    |> SupportTicket.changeset(%{
      status: :closed,
      resolution_note: resolution_note,
      closed_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  defp classify_priority(subject) do
    cond do
      String.contains?(subject, ["urgent", "down", "cannot access"]) -> :high
      String.contains?(subject, ["billing", "charge", "invoice"]) -> :medium
      true -> :low
    end
  end

  # VALIDATION: SMELL END
end
```
