## Smell Metadata

- **Smell:** Shotgun Surgery
- **Expected Smell Location:** Functions `route_to_queue/1`, `auto_assign?/1` in `Support.TicketRouter`; `response_time_hours/1`, `resolve_time_hours/1` in `Support.SLAPolicy`; `escalation_threshold_hours/1`, `notify_on_breach?/1` in `Support.EscalationManager`
- **Affected Functions:** See above (6 functions across 3 modules)
- **Explanation:** Adding a new ticket priority level (e.g., `:critical`) requires scattered changes across three separate support modules. Routing rules, SLA targets, and escalation thresholds are each independently defined per priority, so every module must be modified for a single new priority level.

```elixir
defmodule Support.TicketRouter do
  @moduledoc """
  Determines the correct agent queue and assignment strategy for incoming
  support tickets based on their priority classification.
  """

  # VALIDATION: SMELL START - Shotgun Surgery
  # VALIDATION: This is a smell because adding a new priority level (e.g., :critical)
  # VALIDATION: requires new clauses in route_to_queue/1 and auto_assign?/1 here,
  # VALIDATION: AND independent changes in Support.SLAPolicy and Support.EscalationManager.

  @spec route_to_queue(atom()) :: String.t()
  def route_to_queue(:low),    do: "general"
  def route_to_queue(:medium), do: "standard"
  def route_to_queue(:high),   do: "priority"

  @spec auto_assign?(atom()) :: boolean()
  def auto_assign?(:low),    do: false
  def auto_assign?(:medium), do: true
  def auto_assign?(:high),   do: true

  # VALIDATION: SMELL END

  def assign(ticket) do
    queue      = route_to_queue(ticket.priority)
    auto       = auto_assign?(ticket.priority)
    agent      = if auto, do: find_available_agent(queue), else: nil

    %{ticket |
      queue:      queue,
      agent_id:   agent && agent.id,
      status:     if(agent, do: :assigned, else: :queued),
      assigned_at: if(agent, do: DateTime.utc_now(), else: nil)
    }
  end

  defp find_available_agent(queue) do
    nil
  end
end

defmodule Support.SLAPolicy do
  @moduledoc """
  Defines first-response and resolution time targets for each priority
  level, in accordance with customer support agreements.
  """

  # VALIDATION: SMELL START - Shotgun Surgery
  # VALIDATION: response_time_hours/1 and resolve_time_hours/1 both require new
  # VALIDATION: clauses per priority, completely independent of TicketRouter and
  # VALIDATION: EscalationManager.

  @spec response_time_hours(atom()) :: pos_integer()
  def response_time_hours(:low),    do: 48
  def response_time_hours(:medium), do: 8
  def response_time_hours(:high),   do: 2

  @spec resolve_time_hours(atom()) :: pos_integer()
  def resolve_time_hours(:low),    do: 120
  def resolve_time_hours(:medium), do: 48
  def resolve_time_hours(:high),   do: 12

  # VALIDATION: SMELL END

  def sla_status(ticket) do
    now          = DateTime.utc_now()
    age_hours    = DateTime.diff(now, ticket.created_at, :second) / 3600
    first_resp   = ticket.first_response_at

    response_ok =
      case first_resp do
        nil   -> age_hours <= response_time_hours(ticket.priority)
        resp  -> DateTime.diff(resp, ticket.created_at, :second) / 3600 <=
                   response_time_hours(ticket.priority)
      end

    resolution_ok =
      if ticket.resolved_at do
        DateTime.diff(ticket.resolved_at, ticket.created_at, :second) / 3600 <=
          resolve_time_hours(ticket.priority)
      else
        age_hours <= resolve_time_hours(ticket.priority)
      end

    cond do
      response_ok and resolution_ok -> :compliant
      not response_ok               -> :response_breached
      true                          -> :resolution_breached
    end
  end
end

defmodule Support.EscalationManager do
  @moduledoc """
  Monitors open tickets and triggers escalation workflows when
  thresholds are exceeded relative to priority-specific time limits.
  """

  # VALIDATION: SMELL START - Shotgun Surgery
  # VALIDATION: escalation_threshold_hours/1 and notify_on_breach?/1 are yet more
  # VALIDATION: scattered change points that must be updated per new priority level.

  @spec escalation_threshold_hours(atom()) :: pos_integer()
  def escalation_threshold_hours(:low),    do: 72
  def escalation_threshold_hours(:medium), do: 16
  def escalation_threshold_hours(:high),   do: 4

  @spec notify_on_breach?(atom()) :: boolean()
  def notify_on_breach?(:low),    do: false
  def notify_on_breach?(:medium), do: true
  def notify_on_breach?(:high),   do: true

  # VALIDATION: SMELL END

  def check_and_escalate(tickets) do
    now = DateTime.utc_now()

    tickets
    |> Enum.filter(fn t -> t.status not in [:resolved, :closed] end)
    |> Enum.each(fn ticket ->
      age_hours = DateTime.diff(now, ticket.created_at, :second) / 3600
      threshold = escalation_threshold_hours(ticket.priority)

      if age_hours > threshold do
        escalate(ticket)

        if notify_on_breach?(ticket.priority) do
          Support.Notifications.alert_manager(ticket)
        end
      end
    end)
  end

  defp escalate(ticket) do
    IO.inspect(ticket.id, label: "[Escalation] Escalating ticket")
  end
end
```
