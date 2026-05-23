```elixir
defmodule Support.Tickets do
  @moduledoc """
  Manages the lifecycle of customer support tickets, including
  creation, assignment, escalation, and resolution workflows.
  """

  alias Support.Repo
  alias Support.Ticket
  alias Support.Agent
  alias Support.Notification

  @max_open_tickets_per_agent 20

  @doc """
  Assigns an open ticket to an available support agent.
  """
  def assign(%Ticket{} = ticket, %Agent{} = agent) do
    open_count = Repo.count(Ticket, assignee_id: agent.id, status: :open)

    cond do
      agent.status != :active ->
        {:error, :agent_unavailable}

      agent.department != ticket.department ->
        {:error, :department_mismatch}

      open_count >= @max_open_tickets_per_agent ->
        {:error, :agent_at_capacity}

      true ->
        :eligible
    end
    |> case do
      :eligible ->
        updated = %{ticket | assignee_id: agent.id, status: :open, assigned_at: DateTime.utc_now()}
        Repo.update(updated)
        Notification.send(agent, :ticket_assigned, ticket)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Escalates an unresolved ticket to a senior agent.
  The target agent must meet eligibility requirements.
  """
  def escalate(%Ticket{} = ticket, %Agent{} = senior_agent) do
    open_count = Repo.count(Ticket, assignee_id: senior_agent.id, status: :open)

    cond do
      senior_agent.status != :active ->
        {:error, :agent_unavailable}

      senior_agent.department != ticket.department ->
        {:error, :department_mismatch}

      open_count >= @max_open_tickets_per_agent ->
        {:error, :agent_at_capacity}

      true ->
        :eligible
    end
    |> case do
      :eligible ->
        updated = %{
          ticket
          | assignee_id: senior_agent.id,
            priority: bump_priority(ticket.priority),
            escalated: true,
            escalated_at: DateTime.utc_now()
        }

        Repo.update(updated)
        Notification.send(senior_agent, :ticket_escalated, ticket)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Marks a ticket as resolved with a resolution note.
  """
  def resolve(%Ticket{} = ticket, resolution_note) do
    updated = %{
      ticket
      | status: :resolved,
        resolution_note: resolution_note,
        resolved_at: DateTime.utc_now()
    }

    Repo.update(updated)
  end

  @doc """
  Returns all open tickets for a given agent sorted by priority.
  """
  def open_for_agent(%Agent{} = agent) do
    Repo.all_by(Ticket, assignee_id: agent.id, status: :open)
    |> Enum.sort_by(& &1.priority_order)
  end

  defp bump_priority(:low), do: :medium
  defp bump_priority(:medium), do: :high
  defp bump_priority(:high), do: :critical
  defp bump_priority(other), do: other
end
```
