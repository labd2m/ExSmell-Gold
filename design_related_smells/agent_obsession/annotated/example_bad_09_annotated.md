# Annotated Example 09 — Agent Obsession

## Metadata

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `SupportTicket`, `AgentAssigner`, `EscalationPolicy`, and `TicketReporter` all interact directly with the Agent PID
- **Affected functions:** `SupportTicket.open/3`, `AgentAssigner.assign/3`, `EscalationPolicy.escalate/2`, `TicketReporter.export/1`
- **Short explanation:** A support ticket's lifecycle state is maintained in an Agent, but the responsibility to interact with it is spread across four distinct modules. Each module reads and writes its own portion of the state without an owning abstraction.

---

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

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because SupportTicket directly calls
  # Agent.update/2 to update ticket status and append to the history log.
  # No single module owns the Agent API, so any module with the PID
  # can write whatever it wants into the shared ticket state.
  def close(pid, resolution) do
    Agent.update(pid, fn state ->
      event = %{action: :closed, resolution: resolution, at: DateTime.utc_now()}
      %{state | status: :closed, resolution: resolution, closed_at: DateTime.utc_now(),
        history: [event | state.history]}
    end)
    :ok
  end
  # VALIDATION: SMELL END

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

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because AgentAssigner directly calls
  # Agent.update/2 to embed agent assignment info into the ticket state,
  # relying on the same PID and map structure used by SupportTicket without
  # any encapsulation. It also writes to the :history key it didn't define.
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
  # VALIDATION: SMELL END

  def current_assignee(pid) do
    Agent.get(pid, fn state -> Map.get(state, :assigned_to) end)
  end
end

defmodule EscalationPolicy do
  @moduledoc """
  Applies escalation rules to tickets based on age and priority.
  """

  @sla_hours %{normal: 24, high: 8, critical: 2}

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because EscalationPolicy calls Agent.get/2
  # and Agent.update/2 directly to read ticket age/priority and inject
  # escalation metadata. It is coupled to keys written by SupportTicket
  # and AgentAssigner, none of which it controls.
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
  # VALIDATION: SMELL END
end

defmodule TicketReporter do
  @moduledoc """
  Generates structured reports from support ticket data.
  """

  def export(pid) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because TicketReporter reads the raw Agent
    # state via Agent.get/2 and accesses every key written by SupportTicket,
    # AgentAssigner, and EscalationPolicy. It is fully coupled to their
    # combined output format and would break if any upstream module changed
    # its state structure.
    state = Agent.get(pid, fn s -> s end)
    # VALIDATION: SMELL END

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
