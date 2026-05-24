```elixir
defmodule MyApp.SupportDesk do
  @moduledoc """
  Handles customer support ticket lifecycle, SLA breach detection,
  agent notes, and SLA performance reporting.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.{Ticket, AgentNote, SLAEvent}
  import Ecto.Query

  @sla_response_minutes %{low: 480, medium: 120, high: 30}
  @sla_resolution_minutes %{low: 2880, medium: 720, high: 240}



  @doc """
  Opens a new support ticket for a customer.
  """
  def create_ticket(customer_id, subject, body) do
    priority = infer_priority(subject)

    %Ticket{}
    |> Ticket.changeset(%{
      customer_id: customer_id,
      subject: subject,
      body: body,
      status: :open,
      priority: priority,
      opened_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  @doc """
  Assigns a ticket to a support agent.
  """
  def assign_ticket(%Ticket{} = ticket, agent_id) do
    ticket
    |> Ticket.changeset(%{
      assigned_to: agent_id,
      status: :in_progress,
      first_response_at: ticket.first_response_at || DateTime.utc_now()
    })
    |> Repo.update()
  end

  @doc """
  Escalates a ticket to a higher priority and notifies management.
  """
  def escalate_ticket(%Ticket{priority: :high}, _reason), do: {:error, :already_highest_priority}

  def escalate_ticket(%Ticket{} = ticket, reason) do
    next_priority = %{low: :medium, medium: :high}[ticket.priority]

    ticket
    |> Ticket.changeset(%{priority: next_priority, escalation_reason: reason, escalated_at: DateTime.utc_now()})
    |> Repo.update()
    |> case do
      {:ok, updated} = result ->
        MyApp.Notifications.alert_management("Ticket #{updated.id} escalated: #{reason}")
        result

      error ->
        error
    end
  end

  defp infer_priority(subject) do
    cond do
      String.contains?(subject, ["critical", "down", "data loss"]) -> :high
      String.contains?(subject, ["slow", "billing", "error"]) -> :medium
      true -> :low
    end
  end


  @doc """
  Checks whether a ticket has breached its SLA thresholds and records events.
  """
  def check_sla_breach(%Ticket{} = ticket) do
    now = DateTime.utc_now()
    priority = ticket.priority

    response_limit = Map.get(@sla_response_minutes, priority)
    resolution_limit = Map.get(@sla_resolution_minutes, priority)

    minutes_open = DateTime.diff(now, ticket.opened_at, :second) / 60

    response_breached =
      is_nil(ticket.first_response_at) and minutes_open > response_limit

    resolution_breached =
      ticket.status not in [:resolved, :closed] and minutes_open > resolution_limit

    if response_breached or resolution_breached do
      %SLAEvent{}
      |> SLAEvent.changeset(%{
        ticket_id: ticket.id,
        breach_type: if(response_breached, do: :response, else: :resolution),
        priority: priority,
        occurred_at: now
      })
      |> Repo.insert()

      {:breach, %{response: response_breached, resolution: resolution_breached}}
    else
      {:ok, :within_sla}
    end
  end


  @doc """
  Records an internal note added by a support agent.
  """
  def record_agent_note(%Ticket{} = ticket, agent_id, note_body) do
    %AgentNote{}
    |> AgentNote.changeset(%{
      ticket_id: ticket.id,
      agent_id: agent_id,
      body: note_body,
      noted_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end


  @doc """
  Generates a summary of SLA breach counts for a given date range.
  """
  def generate_sla_report(%Date{} = from_date, %Date{} = to_date) do
    rows =
      from(e in SLAEvent,
        where: fragment("DATE(?)", e.occurred_at) >= ^from_date,
        where: fragment("DATE(?)", e.occurred_at) <= ^to_date,
        group_by: [e.priority, e.breach_type],
        select: %{
          priority: e.priority,
          breach_type: e.breach_type,
          count: count(e.id)
        }
      )
      |> Repo.all()

    total_breaches = Enum.sum(Enum.map(rows, & &1.count))

    %{
      period: "#{from_date} – #{to_date}",
      total_breaches: total_breaches,
      breakdown: rows
    }
  end

end
```
