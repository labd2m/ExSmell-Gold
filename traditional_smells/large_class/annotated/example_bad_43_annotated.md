# Annotated Example — Large Module

- **Smell name:** Large Class (Large Module)
- **Expected smell location:** The entire `CustomerService` module
- **Affected functions:** `open_ticket/2`, `assign_ticket/2`, `add_note/2`, `resolve_ticket/2`, `escalate_ticket/2`, `send_reply/3`, `rate_support/2`, `fetch_customer_history/1`, `generate_sla_report/2`, `export_tickets_csv/2`
- **Short explanation:** `CustomerService` is responsible for ticket lifecycle management (open, assign, resolve, escalate), internal note-taking, outbound reply sending, customer satisfaction ratings, history lookup, SLA analytics, and CSV export. These are at least five distinct bounded contexts that should live in separate modules.

```elixir
# VALIDATION: SMELL START - Large Class (Large Module)
# VALIDATION: This is a smell because CustomerService handles ticket CRUD and
# lifecycle, note management, reply delivery, CSAT ratings, customer history
# retrieval, SLA reporting, and CSV export in a single module — far too many
# responsibilities for one coherent module.
defmodule CustomerService do
  @moduledoc """
  Full customer-support lifecycle: ticket creation, assignment, escalation,
  resolution, internal notes, outbound replies, CSAT ratings, history lookup,
  SLA analytics, and export utilities.
  """

  require Logger
  import Ecto.Query
  alias Support.Repo
  alias Support.Ticket
  alias Support.TicketNote
  alias Support.TicketReply
  alias Support.SatisfactionRating

  @sla_response_hours 4
  @sla_resolution_hours 48

  # --- Ticket creation ---

  def open_ticket(customer_id, params) do
    attrs = %{
      customer_id: customer_id,
      subject: params[:subject],
      body: params[:body],
      priority: params[:priority] || :normal,
      channel: params[:channel] || :email,
      status: :open,
      opened_at: DateTime.utc_now()
    }

    case Repo.insert(Ticket.changeset(%Ticket{}, attrs)) do
      {:ok, ticket} ->
        Logger.info("Ticket #{ticket.id} opened by customer #{customer_id}")
        {:ok, ticket}

      {:error, cs} ->
        {:error, cs}
    end
  end

  # --- Assignment ---

  def assign_ticket(%Ticket{} = ticket, agent_id) do
    ticket
    |> Ticket.changeset(%{assigned_to: agent_id, status: :assigned, assigned_at: DateTime.utc_now()})
    |> Repo.update()
  end

  # --- Internal notes ---

  def add_note(%Ticket{} = ticket, %{agent_id: agent_id, body: body}) do
    attrs = %{ticket_id: ticket.id, agent_id: agent_id, body: body, created_at: DateTime.utc_now()}

    case Repo.insert(TicketNote.changeset(%TicketNote{}, attrs)) do
      {:ok, note} -> {:ok, note}
      {:error, cs} -> {:error, cs}
    end
  end

  # --- Resolution ---

  def resolve_ticket(%Ticket{status: :resolved}), do: {:error, :already_resolved}

  def resolve_ticket(%Ticket{} = ticket) do
    with {:ok, resolved} <-
           ticket
           |> Ticket.changeset(%{status: :resolved, resolved_at: DateTime.utc_now()})
           |> Repo.update() do
      customer = Repo.get!(Support.Customer, ticket.customer_id)

      Mailer.deliver(%{
        to: customer.email,
        subject: "Your support ticket ##{ticket.id} has been resolved",
        text_body: "We hope we resolved your issue. If you need further help, please reply."
      })

      {:ok, resolved}
    end
  end

  # --- Escalation ---

  def escalate_ticket(%Ticket{} = ticket, escalation_reason) do
    ticket
    |> Ticket.changeset(%{
         priority: :urgent,
         status: :escalated,
         escalation_reason: escalation_reason,
         escalated_at: DateTime.utc_now()
       })
    |> Repo.update()
  end

  # --- Outbound replies ---

  def send_reply(%Ticket{} = ticket, agent_id, reply_body) do
    customer = Repo.get!(Support.Customer, ticket.customer_id)

    reply_attrs = %{
      ticket_id: ticket.id,
      agent_id: agent_id,
      body: reply_body,
      sent_at: DateTime.utc_now()
    }

    with {:ok, reply} <- Repo.insert(TicketReply.changeset(%TicketReply{}, reply_attrs)),
         {:ok, _} <-
           Mailer.deliver(%{
             to: customer.email,
             subject: "Re: #{ticket.subject} [##{ticket.id}]",
             text_body: reply_body
           }) do
      {:ok, reply}
    end
  end

  # --- CSAT ratings ---

  def rate_support(%Ticket{} = ticket, %{score: score, comment: comment})
      when score in 1..5 do
    attrs = %{
      ticket_id: ticket.id,
      customer_id: ticket.customer_id,
      score: score,
      comment: comment,
      rated_at: DateTime.utc_now()
    }

    case Repo.insert(SatisfactionRating.changeset(%SatisfactionRating{}, attrs)) do
      {:ok, rating} ->
        Logger.info("CSAT #{score}/5 recorded for ticket #{ticket.id}")
        {:ok, rating}

      {:error, cs} ->
        {:error, cs}
    end
  end

  def rate_support(_, _), do: {:error, :invalid_score}

  # --- Customer history ---

  def fetch_customer_history(customer_id) do
    tickets =
      from(t in Ticket,
        where: t.customer_id == ^customer_id,
        order_by: [desc: t.opened_at],
        preload: [:notes, :replies]
      )
      |> Repo.all()

    ratings =
      from(r in SatisfactionRating, where: r.customer_id == ^customer_id)
      |> Repo.all()

    %{tickets: tickets, satisfaction_ratings: ratings}
  end

  # --- SLA reporting ---

  def generate_sla_report(from_date, to_date) do
    tickets =
      from(t in Ticket,
        where: t.opened_at >= ^from_date and t.opened_at <= ^to_date
      )
      |> Repo.all()

    breached_response =
      Enum.count(tickets, fn t ->
        t.assigned_at &&
          DateTime.diff(t.assigned_at, t.opened_at, :hour) > @sla_response_hours
      end)

    breached_resolution =
      Enum.count(tickets, fn t ->
        t.resolved_at &&
          DateTime.diff(t.resolved_at, t.opened_at, :hour) > @sla_resolution_hours
      end)

    total = length(tickets)

    %{
      period: %{from: from_date, to: to_date},
      total_tickets: total,
      sla_response_breaches: breached_response,
      sla_resolution_breaches: breached_resolution,
      response_breach_rate: if(total > 0, do: Float.round(breached_response / total * 100, 1), else: 0.0),
      resolution_breach_rate: if(total > 0, do: Float.round(breached_resolution / total * 100, 1), else: 0.0)
    }
  end

  # --- CSV export ---

  def export_tickets_csv(from_date, to_date) do
    tickets =
      from(t in Ticket,
        where: t.opened_at >= ^from_date and t.opened_at <= ^to_date,
        order_by: [asc: t.opened_at]
      )
      |> Repo.all()

    header = "id,customer_id,subject,priority,status,channel,opened_at,resolved_at\n"

    rows =
      Enum.map(tickets, fn t ->
        "#{t.id},#{t.customer_id},\"#{t.subject}\",#{t.priority},#{t.status},#{t.channel},#{t.opened_at},#{t.resolved_at}\n"
      end)

    [header | rows] |> Enum.join()
  end
end
# VALIDATION: SMELL END
```
