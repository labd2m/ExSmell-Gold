```elixir
defmodule Support.SlaPolicy do
  @moduledoc """
  Evaluates support ticket SLA compliance, computes breach deadlines,
  and generates escalation recommendations for the customer support platform.
  """

  @sla_minutes %{
    critical: 60,
    high: 240,
    medium: 1_440,
    low: 4_320
  }


  def deadline_for(ticket) do
    minutes = Map.get(@sla_minutes, ticket.priority, @sla_minutes.low)
    DateTime.add(ticket.opened_at, minutes * 60, :second)
  end

  def evaluate(ticket) do
    require Support.SlaPolicy

    deadline = deadline_for(ticket)
    now = DateTime.utc_now()

    breached = Support.SlaPolicy.breached?(deadline, now)
    elapsed = DateTime.diff(now, ticket.opened_at, :minute)
    remaining = DateTime.diff(deadline, now, :minute)

    %{
      ticket_id: ticket.id,
      priority: ticket.priority,
      opened_at: ticket.opened_at,
      deadline: deadline,
      breached: breached,
      elapsed_minutes: elapsed,
      remaining_minutes: max(remaining, 0),
      status: if(breached, do: :breached, else: :within_sla)
    }
  end

  def evaluate_batch(tickets) do
    Enum.map(tickets, &evaluate/1)
  end

  def at_risk?(ticket, warning_threshold_minutes \\ 30) do
    require Support.SlaPolicy

    deadline = deadline_for(ticket)
    now = DateTime.utc_now()
    minutes_left = DateTime.diff(deadline, now, :minute)

    not Support.SlaPolicy.breached?(deadline, now) and minutes_left <= warning_threshold_minutes
  end

  def breached_tickets(tickets) do
    require Support.SlaPolicy

    Enum.filter(tickets, fn ticket ->
      deadline = deadline_for(ticket)
      Support.SlaPolicy.breached?(deadline, DateTime.utc_now())
    end)
  end

  def escalation_priority(ticket) do
    sla = evaluate(ticket)

    cond do
      sla.breached and ticket.priority == :critical -> :immediate
      sla.breached -> :urgent
      at_risk?(ticket, 15) -> :warning
      true -> :normal
    end
  end

  def summary_report(tickets) do
    evaluations = evaluate_batch(tickets)
    breached = Enum.count(evaluations, & &1.breached)
    within = length(evaluations) - breached

    %{
      total: length(evaluations),
      breached: breached,
      within_sla: within,
      breach_rate: if(length(evaluations) > 0, do: breached / length(evaluations), else: 0.0),
      by_priority: Enum.group_by(evaluations, & &1.priority)
    }
  end
end
```
