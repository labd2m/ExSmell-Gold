# Annotated Example – Bad Code

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `TicketCreator`, `TicketAssigner`, `TicketResolver`, and `SupportDashboard`
- **Affected functions:** `TicketCreator.open/2`, `TicketAssigner.assign/3`, `TicketResolver.resolve/3`, `SupportDashboard.agent_workload/1`
- **Short explanation:** The shared support-ticket Agent is accessed directly by four distinct modules. Each independently reads and writes the tickets map without routing through a centralised owner, coupling each module to the Agent's internal data format.

```elixir
defmodule SupportAgent do
  @moduledoc "Shared Agent for the support ticket system state."

  def start_link(_opts \\ []) do
    Agent.start_link(
      fn ->
        %{
          tickets: %{},
          agents: %{},
          activity_log: []
        }
      end,
      name: __MODULE__
    )
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}
  end
end

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because TicketCreator directly calls Agent.update to
# insert a new ticket into the shared Agent's tickets map, independently owning the
# ticket record format without any centralised owner.
defmodule TicketCreator do
  @moduledoc "Opens new support tickets from customer reports."

  require Logger

  @priorities [:critical, :high, :medium, :low]
  @categories [:billing, :technical, :account, :general, :feature_request]

  def open(agent, %{
        customer_id: customer_id,
        subject: subject,
        body: body,
        priority: priority,
        category: category
      } = attrs)
      when priority in @priorities and category in @categories do
    ticket_id = "TKT-" <> String.pad_leading(to_string(:erlang.unique_integer([:positive])), 6, "0")

    ticket = %{
      id: ticket_id,
      customer_id: customer_id,
      subject: subject,
      body: body,
      priority: priority,
      category: category,
      status: :open,
      assigned_to: nil,
      tags: Map.get(attrs, :tags, []),
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now(),
      comments: []
    }

    Agent.update(agent, fn state ->
      %{state | tickets: Map.put(state.tickets, ticket_id, ticket)}
    end)

    Logger.info("Opened ticket #{ticket_id}: #{subject} [#{priority}/#{category}]")
    {:ok, ticket_id}
  end

  def open(_agent, attrs), do: {:error, {:invalid_ticket_attrs, attrs}}
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because TicketAssigner directly calls Agent.get and
# Agent.update to check agent availability and assign tickets, taking implicit
# ownership of both the agents and tickets sub-maps in the shared Agent.
defmodule TicketAssigner do
  @moduledoc "Assigns open tickets to support agents."

  require Logger

  def assign(agent, ticket_id, support_agent_id) do
    ticket = Agent.get(agent, fn state -> Map.get(state.tickets, ticket_id) end)
    support_agent = Agent.get(agent, fn state -> Map.get(state.agents, support_agent_id) end)

    cond do
      is_nil(ticket) ->
        {:error, :ticket_not_found}

      ticket.status != :open ->
        {:error, {:cannot_assign_ticket_with_status, ticket.status}}

      is_nil(support_agent) ->
        {:error, :agent_not_found}

      not support_agent.available ->
        {:error, :agent_unavailable}

      true ->
        log_entry = %{
          action: :assigned,
          ticket_id: ticket_id,
          agent_id: support_agent_id,
          at: DateTime.utc_now()
        }

        Agent.update(agent, fn state ->
          updated_ticket = %{ticket | assigned_to: support_agent_id, status: :in_progress, updated_at: DateTime.utc_now()}

          %{
            state
            | tickets: Map.put(state.tickets, ticket_id, updated_ticket),
              activity_log: [log_entry | state.activity_log]
          }
        end)

        Logger.info("Assigned ticket #{ticket_id} to agent #{support_agent_id}")
        :ok
    end
  end
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because TicketResolver directly calls Agent.update to
# transition ticket status to :resolved and append a resolution note, independently
# manipulating the Agent's tickets map.
defmodule TicketResolver do
  @moduledoc "Closes and resolves support tickets."

  require Logger

  def resolve(agent, ticket_id, %{resolution: resolution, resolved_by: resolved_by}) do
    case Agent.get(agent, fn state -> Map.get(state.tickets, ticket_id) end) do
      nil ->
        {:error, :ticket_not_found}

      %{status: :resolved} ->
        {:error, :already_resolved}

      ticket ->
        comment = %{
          author: resolved_by,
          body: resolution,
          type: :resolution,
          posted_at: DateTime.utc_now()
        }

        log_entry = %{
          action: :resolved,
          ticket_id: ticket_id,
          resolved_by: resolved_by,
          at: DateTime.utc_now()
        }

        Agent.update(agent, fn state ->
          updated_ticket = %{
            ticket
            | status: :resolved,
              resolved_at: DateTime.utc_now(),
              updated_at: DateTime.utc_now(),
              comments: ticket.comments ++ [comment]
          }

          %{
            state
            | tickets: Map.put(state.tickets, ticket_id, updated_ticket),
              activity_log: [log_entry | state.activity_log]
          }
        end)

        Logger.info("Resolved ticket #{ticket_id} by #{resolved_by}")
        :ok
    end
  end
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because SupportDashboard directly calls Agent.get to
# scan the raw tickets map and group by assignee, coupling dashboard reporting to
# the internal structure of the shared Agent.
defmodule SupportDashboard do
  @moduledoc "Provides operational metrics and workload views for the support team."

  def agent_workload(agent) do
    Agent.get(agent, fn state ->
      state.tickets
      |> Map.values()
      |> Enum.filter(&(&1.status == :in_progress and not is_nil(&1.assigned_to)))
      |> Enum.group_by(& &1.assigned_to)
      |> Map.new(fn {agent_id, tickets} ->
        {agent_id, %{count: length(tickets), priorities: Enum.map(tickets, & &1.priority)}}
      end)
    end)
  end

  def open_by_category(agent) do
    Agent.get(agent, fn state ->
      state.tickets
      |> Map.values()
      |> Enum.filter(&(&1.status == :open))
      |> Enum.group_by(& &1.category)
      |> Map.new(fn {cat, tickets} -> {cat, length(tickets)} end)
    end)
  end

  def sla_breached(agent, sla_minutes \\ 480) do
    cutoff = DateTime.add(DateTime.utc_now(), -sla_minutes * 60, :second)

    Agent.get(agent, fn state ->
      state.tickets
      |> Map.values()
      |> Enum.filter(fn t ->
        t.status in [:open, :in_progress] and
          DateTime.compare(t.created_at, cutoff) == :lt
      end)
    end)
  end
end
# VALIDATION: SMELL END
```
