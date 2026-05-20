```elixir
defmodule SupportTicketHandler do
  @moduledoc """
  Orchestrates customer support ticket lifecycle events including
  creation, escalation to senior agents, and resolution/closure workflows.
  """

  alias SupportTicketHandler.{
    TicketCreation,
    EscalationRequest,
    ClosureRequest,
    TicketStore,
    AgentRouter,
    SLAEngine,
    KnowledgeBase,
    CustomerNotifier,
    AgentNotifier,
    AuditLog
  }

  require Logger

  @doc """
  Handle a support ticket lifecycle event.

  Accepts a `%TicketCreation{}`, `%EscalationRequest{}`, or `%ClosureRequest{}`
  and performs the corresponding support operation.

  ## Examples

      iex> SupportTicketHandler.handle(%TicketCreation{customer_id: 42, subject: "Login broken", priority: :high})
      {:ok, %Ticket{id: "tkt_001", status: :open}}

  """
  def handle(%TicketCreation{
        customer_id: customer_id,
        subject: subject,
        body: body,
        priority: priority,
        channel: channel,
        attachments: attachments
      }) do
    with {:ok, suggestions} <- KnowledgeBase.suggest_articles(subject, body),
         {:ok, agent} <- AgentRouter.assign(priority, channel),
         {:ok, ticket} <-
           TicketStore.create(%{
             customer_id: customer_id,
             subject: subject,
             body: body,
             priority: priority,
             channel: channel,
             attachments: attachments,
             assigned_agent_id: agent.id,
             status: :open,
             opened_at: DateTime.utc_now()
           }),
         :ok <- SLAEngine.schedule_breach_alert(ticket.id, priority),
         :ok <- CustomerNotifier.send_ticket_opened(customer_id, ticket, suggestions),
         :ok <- AgentNotifier.send_new_assignment(agent.id, ticket) do
      Logger.info("Ticket #{ticket.id} opened for customer #{customer_id}, assigned to agent #{agent.id}")
      {:ok, ticket}
    end
  end

  # handle escalation of an open ticket to senior support tier
  def handle(%EscalationRequest{
        ticket_id: ticket_id,
        reason: reason,
        escalated_by: agent_id,
        target_tier: tier
      })
      when tier in [:tier2, :tier3, :specialist] do
    with {:ok, ticket} <- TicketStore.find(ticket_id),
         :ok <- validate_escalatable(ticket),
         {:ok, senior_agent} <- AgentRouter.assign_senior(tier, ticket.topic),
         {:ok, updated} <-
           TicketStore.update(ticket_id, %{
             status: :escalated,
             assigned_agent_id: senior_agent.id,
             escalation_tier: tier,
             escalation_reason: reason,
             escalated_at: DateTime.utc_now()
           }),
         :ok <-
           AuditLog.append(:ticket_escalated, %{
             ticket_id: ticket_id,
             from_agent: agent_id,
             to_agent: senior_agent.id,
             tier: tier,
             reason: reason
           }),
         :ok <- AgentNotifier.send_escalation_notice(senior_agent.id, updated),
         :ok <- CustomerNotifier.send_escalation_update(ticket.customer_id, updated) do
      Logger.info("Ticket #{ticket_id} escalated to #{tier} agent #{senior_agent.id}")
      {:ok, updated}
    end
  end

  # handle ticket closure with resolution summary
  def handle(%ClosureRequest{
        ticket_id: ticket_id,
        resolution: resolution,
        closed_by: agent_id,
        satisfaction_survey: send_survey
      }) do
    with {:ok, ticket} <- TicketStore.find(ticket_id),
         :ok <- validate_closeable(ticket),
         {:ok, updated} <-
           TicketStore.update(ticket_id, %{
             status: :closed,
             resolution: resolution,
             closed_by: agent_id,
             closed_at: DateTime.utc_now()
           }),
         :ok <- SLAEngine.record_resolution(ticket_id, ticket.opened_at, DateTime.utc_now()),
         :ok <- maybe_send_survey(send_survey, ticket.customer_id, ticket_id),
         :ok <- CustomerNotifier.send_ticket_closed(ticket.customer_id, updated) do
      Logger.info("Ticket #{ticket_id} closed by agent #{agent_id}")
      {:ok, updated}
    end
  end

  defp validate_escalatable(%{status: :open}), do: :ok
  defp validate_escalatable(%{status: :pending}), do: :ok
  defp validate_escalatable(%{status: s}), do: {:error, {:cannot_escalate, s}}

  defp validate_closeable(%{status: s}) when s in [:open, :escalated, :pending], do: :ok
  defp validate_closeable(%{status: s}), do: {:error, {:cannot_close, s}}

  defp maybe_send_survey(true, customer_id, ticket_id) do
    CustomerNotifier.send_satisfaction_survey(customer_id, ticket_id)
  end

  defp maybe_send_survey(false, _customer_id, _ticket_id), do: :ok
end
```
