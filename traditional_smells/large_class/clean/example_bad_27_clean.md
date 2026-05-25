```elixir
defmodule CustomerRelations do
  @moduledoc """
  Manages all CRM operations including profiles, segmentation, loyalty, and support.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.CRM.{
    Customer,
    CustomerSegment,
    Interaction,
    LoyaltyAccount,
    LoyaltyTransaction,
    SupportTicket,
    TicketComment
  }
  alias MyApp.Mailer

  @points_per_dollar 10
  @points_expiry_months 12
  @vip_spend_threshold Decimal.new(10_000)
  @sla_hours %{low: 72, medium: 24, high: 4, critical: 1}


  def create_customer(attrs) do
    with {:ok, customer} <- Repo.insert(Customer.changeset(%Customer{}, attrs)),
         {:ok, _} <- Repo.insert(%LoyaltyAccount{customer_id: customer.id, points: 0}) do
      Logger.info("Customer #{customer.id} created: #{customer.email}")
      {:ok, customer}
    end
  end

  def update_customer(customer_id, attrs) do
    Repo.get!(Customer, customer_id)
    |> Customer.changeset(attrs)
    |> Repo.update()
  end

  def merge_customers(primary_id, duplicate_id) do
    duplicate = Repo.get!(Customer, duplicate_id)

    Repo.update_all(
      from(i in Interaction, where: i.customer_id == ^duplicate_id),
      set: [customer_id: primary_id]
    )

    Repo.update_all(
      from(t in SupportTicket, where: t.customer_id == ^duplicate_id),
      set: [customer_id: primary_id]
    )

    duplicate |> Customer.changeset(%{status: :merged, merged_into: primary_id}) |> Repo.update()
    Logger.info("Customer #{duplicate_id} merged into #{primary_id}")
  end


  def compute_segment(%Customer{} = customer) do
    total_spend = total_lifetime_spend(customer.id)
    last_purchase_days = days_since_last_purchase(customer.id)
    ticket_count = count_support_tickets(customer.id)

    segment =
      cond do
        Decimal.compare(total_spend, @vip_spend_threshold) == :gt -> :vip
        last_purchase_days > 180 -> :at_risk
        last_purchase_days > 90 -> :dormant
        ticket_count > 5 -> :high_touch
        true -> :standard
      end

    {:ok, _} =
      Repo.insert(%CustomerSegment{
        customer_id: customer.id,
        segment: segment,
        computed_at: DateTime.utc_now()
      },
      on_conflict: {:replace, [:segment, :computed_at]},
      conflict_target: :customer_id
      )

    {:ok, segment}
  end

  defp total_lifetime_spend(customer_id) do
    Repo.one(
      from o in MyApp.Orders.Order,
        where: o.customer_id == ^customer_id and o.status == :delivered,
        select: coalesce(sum(o.total_amount), 0)
    )
  end

  defp days_since_last_purchase(customer_id) do
    last =
      Repo.one(
        from o in MyApp.Orders.Order,
          where: o.customer_id == ^customer_id,
          select: max(o.placed_at)
      )

    if last, do: DateTime.diff(DateTime.utc_now(), last, :day), else: 9999
  end

  defp count_support_tickets(customer_id) do
    Repo.aggregate(from(t in SupportTicket, where: t.customer_id == ^customer_id), :count)
  end


  def log_interaction(customer_id, type, channel, summary, metadata \\ %{}) do
    Repo.insert(%Interaction{
      customer_id: customer_id,
      type: type,
      channel: channel,
      summary: summary,
      metadata: metadata,
      occurred_at: DateTime.utc_now()
    })
  end

  def interaction_timeline(customer_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    type_filter = Keyword.get(opts, :type)

    base = from i in Interaction, where: i.customer_id == ^customer_id, order_by: [desc: i.occurred_at], limit: ^limit

    query = if type_filter, do: from(i in base, where: i.type == ^type_filter), else: base
    Repo.all(query)
  end


  def accrue_points(customer_id, order_amount) do
    points_earned = Decimal.to_integer(Decimal.mult(order_amount, @points_per_dollar))
    account = Repo.get_by!(LoyaltyAccount, customer_id: customer_id)

    new_total = account.points + points_earned
    expires_at = DateTime.add(DateTime.utc_now(), @points_expiry_months * 30 * 86400, :second)

    with {:ok, updated} <-
           account
           |> LoyaltyAccount.changeset(%{points: new_total})
           |> Repo.update(),
         {:ok, _} <-
           Repo.insert(%LoyaltyTransaction{
             loyalty_account_id: account.id,
             delta: points_earned,
             type: :accrual,
             expires_at: expires_at,
             description: "Order reward",
             occurred_at: DateTime.utc_now()
           }) do
      {:ok, updated}
    end
  end

  def redeem_points(customer_id, points_to_redeem) do
    account = Repo.get_by!(LoyaltyAccount, customer_id: customer_id)

    if account.points < points_to_redeem do
      {:error, :insufficient_points}
    else
      new_total = account.points - points_to_redeem

      with {:ok, updated} <-
             account |> LoyaltyAccount.changeset(%{points: new_total}) |> Repo.update(),
           {:ok, _} <-
             Repo.insert(%LoyaltyTransaction{
               loyalty_account_id: account.id,
               delta: -points_to_redeem,
               type: :redemption,
               description: "Points redeemed",
               occurred_at: DateTime.utc_now()
             }) do
        {:ok, updated}
      end
    end
  end


  def open_ticket(customer_id, %{subject: subject, body: body, priority: priority}) do
    sla_deadline =
      DateTime.add(DateTime.utc_now(), Map.get(@sla_hours, priority, 24) * 3600, :second)

    {:ok, ticket} =
      Repo.insert(%SupportTicket{
        customer_id: customer_id,
        subject: subject,
        body: body,
        priority: priority,
        status: :open,
        sla_deadline: sla_deadline,
        opened_at: DateTime.utc_now()
      })

    notify_support_team(ticket)
    {:ok, ticket}
  end

  def add_comment(ticket_id, author_id, body) do
    Repo.insert(%TicketComment{
      ticket_id: ticket_id,
      author_id: author_id,
      body: body,
      posted_at: DateTime.utc_now()
    })
  end

  def close_ticket(ticket_id, resolution) do
    ticket = Repo.get!(SupportTicket, ticket_id)
    customer = Repo.get!(Customer, ticket.customer_id)

    ticket
    |> SupportTicket.changeset(%{status: :closed, resolution: resolution, closed_at: DateTime.utc_now()})
    |> Repo.update()
    |> case do
      {:ok, closed} ->
        Mailer.send(%{
          to: customer.email,
          subject: "Your support ticket ##{ticket_id} has been resolved",
          body: "Resolution: #{resolution}"
        })
        {:ok, closed}

      err -> err
    end
  end

  defp notify_support_team(%SupportTicket{id: id, priority: priority}) do
    Mailer.send(%{
      to: "support@myapp.com",
      subject: "[#{String.upcase(to_string(priority))}] New ticket ##{id}",
      body: "A new #{priority} priority ticket has been opened."
    })
  end
end
```
