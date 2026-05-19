```elixir
defmodule SupportTicket do
  @moduledoc """
  Opens and manages customer support tickets.
  """

  def open(customer_id, subject, body) do
    {:ok, pid} = Agent.start_link(fn ->
      %{
        id: System.unique_integer([:positive]),
        customer_id: customer_id,
        subject: subject,
        body: body,
        priority: :normal,
        status: :open,
        created_at: DateTime.utc_now(),
        history: []
      }
    end)
    {:ok, pid}
  end

  def close(pid, resolution) do
    Agent.update(pid, fn state ->
      event = %{action: :closed, resolution: resolution, at: DateTime.utc_now()}
      %{state | status: :closed, resolution: resolution, closed_at: DateTime.utc_now(),
        history: [event | state.history]}
    end)
    :ok
  end

  def get_ticket(pid) do
    Agent.get(pid, fn state -> state end)
  end

  def add_note(pid, author, note) do
    Agent.update(pid, fn state ->
      event = %{action: :note_added, author: author, note: note, at: DateTime.utc_now()}
      %{state | history: [event | state.history]}
    end)
    :ok
  end
end

defmodule AgentAssigner do
  @moduledoc """
  Assigns support agents to incoming tickets based on workload.
  """

  def assign(pid, agent_id, team) do
    Agent.update(pid, fn state ->
      event = %{
        action: :assigned,
        agent_id: agent_id,
        team: team,
        at: DateTime.utc_now()
      }
      %{state |
        assigned_to: agent_id,
        team: team,
        status: :in_progress,
        history: [event | state.history]
      }
    end)
    :ok
  end

  def current_assignee(pid) do
    Agent.get(pid, fn state -> Map.get(state, :assigned_to) end)
  end
end

defmodule EscalationPolicy do
  @moduledoc """
  Applies escalation rules to tickets based on age and priority.
  """

  @sla_hours %{normal: 24, high: 8, critical: 2}

  def escalate(pid, reason) do
    Agent.update(pid, fn state ->
      event = %{action: :escalated, reason: reason, at: DateTime.utc_now()}
      %{state |
        priority: :critical,
        status: :escalated,
        escalated_at: DateTime.utc_now(),
        escalation_reason: reason,
        history: [event | state.history]
      }
    end)
    :ok
  end

  def sla_breached?(pid) do
    Agent.get(pid, fn state ->
      now = DateTime.utc_now()
      created = state.created_at
      elapsed_hours = DateTime.diff(now, created, :second) / 3600
      allowed = Map.get(@sla_hours, state.priority, 24)
      elapsed_hours > allowed
    end)
  end
end

defmodule TicketReporter do
  @moduledoc """
  Generates structured reports from support ticket data.
  """

  def export(pid) do
    state = Agent.get(pid, fn s -> s end)

    %{
      ticket_id: state.id,
      customer: state.customer_id,
      subject: state.subject,
      status: state.status,
      priority: state.priority,
      assigned_to: Map.get(state, :assigned_to),
      team: Map.get(state, :team),
      escalated: Map.has_key?(state, :escalated_at),
      escalation_reason: Map.get(state, :escalation_reason),
      created_at: state.created_at,
      closed_at: Map.get(state, :closed_at),
      history_count: length(state.history)
    }
  end
end
```
