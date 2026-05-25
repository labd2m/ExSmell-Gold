```elixir
defmodule MyApp.SupportManager do
  @moduledoc """
  Manages support tickets from creation through resolution,
  including SLA compliance, satisfaction ratings, and reporting.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Support.{Ticket, TicketReply, SatisfactionRating, AgentMetric}
  alias MyApp.Accounts.{User, Agent}

  @sla_response_hours %{critical: 1, high: 4, medium: 8, normal: 24}
  @sla_resolve_hours  %{critical: 4, high: 24, medium: 72, normal: 120}


  def open_ticket(%User{} = user, attrs) do
    priority = attrs[:priority] || :normal

    ticket = Repo.insert!(%Ticket{
      user_id:     user.id,
      subject:     attrs[:subject],
      description: attrs[:description],
      priority:    priority,
      status:      :open,
      opened_at:   DateTime.utc_now(),
      sla_due_at:  sla_deadline(:response, priority)
    })

    MyApp.Mailer.deliver(%{
      to:      user.email,
      subject: "[Ticket ##{ticket.id}] #{ticket.subject}",
      body:    "Your support ticket has been received. We'll respond within #{@sla_response_hours[priority]} hour(s)."
    })

    notify_agents_new_ticket(ticket)
    {:ok, ticket}
  end

  def assign_ticket(%Ticket{} = ticket, %Agent{} = agent) do
    if ticket.status == :closed do
      {:error, :ticket_closed}
    else
      Repo.update!(Ticket.changeset(ticket, %{
        assigned_agent_id: agent.id,
        assigned_at:       DateTime.utc_now(),
        status:            :in_progress
      }))

      :ok
    end
  end

  def add_reply(%Ticket{} = ticket, author_id, body) when is_binary(body) do
    reply = Repo.insert!(%TicketReply{
      ticket_id:  ticket.id,
      author_id:  author_id,
      body:       body,
      posted_at:  DateTime.utc_now()
    })

    if is_agent?(author_id) and is_nil(ticket.first_response_at) do
      Repo.update!(Ticket.changeset(ticket, %{first_response_at: DateTime.utc_now()}))
    end

    unless is_agent?(author_id) do
      notify_agent_new_reply(ticket, reply)
    else
      notify_user_new_reply(ticket, reply)
    end

    {:ok, reply}
  end

  def escalate_ticket(%Ticket{} = ticket, reason) do
    Repo.update!(Ticket.changeset(ticket, %{
      priority:      :critical,
      escalated:     true,
      escalated_at:  DateTime.utc_now(),
      escalation_reason: reason,
      sla_due_at:    sla_deadline(:response, :critical)
    }))

    Logger.warning("Ticket #{ticket.id} escalated: #{reason}")
    notify_agents_escalation(ticket)
    :ok
  end

  def resolve_ticket(%Ticket{status: s} = ticket, resolution_note)
      when s in [:open, :in_progress] do
    Repo.update!(Ticket.changeset(ticket, %{
      status:         :resolved,
      resolved_at:    DateTime.utc_now(),
      resolution_note: resolution_note
    }))

    user = Repo.get!(User, ticket.user_id)

    MyApp.Mailer.deliver(%{
      to:      user.email,
      subject: "[Ticket ##{ticket.id}] Resolved",
      body:    "Your ticket has been resolved. Please let us know if you need further assistance."
    })

    schedule_satisfaction_survey(ticket)
    :ok
  end

  def resolve_ticket(%Ticket{status: s}, _), do: {:error, "Cannot resolve ticket in status #{s}"}

  def close_ticket(%Ticket{status: s} = ticket) when s in [:resolved, :in_progress, :open] do
    Repo.update!(Ticket.changeset(ticket, %{status: :closed, closed_at: DateTime.utc_now()}))
    :ok
  end

  def close_ticket(%Ticket{status: s}), do: {:error, "Cannot close ticket in status #{s}"}

  def reopen_ticket(%Ticket{status: :closed} = ticket, reason) do
    Repo.update!(Ticket.changeset(ticket, %{
      status:        :open,
      closed_at:     nil,
      reopen_reason: reason,
      reopened_at:   DateTime.utc_now()
    }))

    notify_agents_new_ticket(ticket)
    :ok
  end

  def reopen_ticket(_, _), do: {:error, :not_closed}


  defp schedule_satisfaction_survey(%Ticket{} = ticket) do
    Logger.info("Scheduling satisfaction survey for ticket #{ticket.id}")
  end

  def rate_experience(%Ticket{status: :resolved} = ticket, rating)
      when rating in 1..5 do
    Repo.insert!(%SatisfactionRating{
      ticket_id:  ticket.id,
      user_id:    ticket.user_id,
      agent_id:   ticket.assigned_agent_id,
      rating:     rating,
      rated_at:   DateTime.utc_now()
    })

    :ok
  end

  def rate_experience(_, _), do: {:error, :not_eligible_for_rating}


  def compute_sla_status(%Ticket{} = ticket) do
    now = DateTime.utc_now()

    first_response_ok =
      if ticket.first_response_at do
        expected = sla_deadline(:response, ticket.priority, ticket.opened_at)
        DateTime.compare(ticket.first_response_at, expected) != :gt
      else
        DateTime.compare(now, sla_deadline(:response, ticket.priority, ticket.opened_at)) != :gt
      end

    resolution_ok =
      if ticket.resolved_at do
        expected = sla_deadline(:resolve, ticket.priority, ticket.opened_at)
        DateTime.compare(ticket.resolved_at, expected) != :gt
      else
        ticket.status != :closed
      end

    %{
      first_response_breached: not first_response_ok,
      resolution_breached:     not resolution_ok,
      overall_status:          if(first_response_ok and resolution_ok, do: :on_track, else: :breached)
    }
  end

  defp sla_deadline(:response, priority, base \\ nil) do
    hours = @sla_response_hours[priority] || 24
    DateTime.add(base || DateTime.utc_now(), hours * 3600, :second)
  end

  defp sla_deadline(:resolve, priority, base \\ nil) do
    hours = @sla_resolve_hours[priority] || 120
    DateTime.add(base || DateTime.utc_now(), hours * 3600, :second)
  end


  def agent_performance_report(agent_id, since) do
    tickets =
      from(t in Ticket,
        where: t.assigned_agent_id == ^agent_id and t.opened_at >= ^since
      )
      |> Repo.all()

    resolved   = Enum.filter(tickets, &(&1.status == :resolved))
    avg_rating = avg_satisfaction(agent_id, since)

    avg_resolve_sec =
      if Enum.empty?(resolved) do
        nil
      else
        total = Enum.sum(Enum.map(resolved, &DateTime.diff(&1.resolved_at, &1.opened_at)))
        div(total, length(resolved))
      end

    %{
      agent_id:             agent_id,
      total_tickets:        length(tickets),
      resolved:             length(resolved),
      avg_resolution_sec:   avg_resolve_sec,
      avg_satisfaction:     avg_rating
    }
  end

  defp avg_satisfaction(agent_id, since) do
    result =
      from(r in SatisfactionRating,
        where: r.agent_id == ^agent_id and r.rated_at >= ^since,
        select: avg(r.rating)
      )
      |> Repo.one()

    result && Float.round(result, 2)
  end

  def ticket_volume_report(start_date, end_date) do
    from(t in Ticket,
      where: t.opened_at >= ^start_date and t.opened_at <= ^end_date,
      group_by: [fragment("DATE(?)", t.opened_at), t.priority],
      select: %{
        date:     fragment("DATE(?)", t.opened_at),
        priority: t.priority,
        count:    count(t.id)
      },
      order_by: [asc: fragment("DATE(?)", t.opened_at)]
    )
    |> Repo.all()
  end


  defp notify_agents_new_ticket(ticket) do
    Logger.info("New ticket #{ticket.id} — notifying available agents")
  end

  defp notify_agent_new_reply(ticket, _reply) do
    Logger.info("Customer replied to ticket #{ticket.id}")
  end

  defp notify_user_new_reply(%Ticket{} = ticket, _reply) do
    user = Repo.get!(User, ticket.user_id)
    MyApp.Mailer.deliver(%{
      to:      user.email,
      subject: "[Ticket ##{ticket.id}] New reply from support",
      body:    "Your support ticket has a new reply."
    })
  end

  defp notify_agents_escalation(ticket) do
    Logger.warning("Ticket #{ticket.id} has been escalated to critical")
  end

  defp is_agent?(user_id) do
    Repo.exists?(from a in Agent, where: a.user_id == ^user_id)
  end
end
```
