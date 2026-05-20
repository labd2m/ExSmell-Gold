# Annotated Example 13 — Complex Extractions in Clauses

## Metadata

| Field                  | Value                                                                                              |
|------------------------|----------------------------------------------------------------------------------------------------|
| **Smell name**         | Complex extractions in clauses                                                                     |
| **Expected location**  | `Support.TicketRouter.route/1`                                                                     |
| **Affected function**  | `route/1`                                                                                          |
| **Short explanation**  | The function selects a clause based on `category` and guards on `severity_score`, but every clause head also destructures `ticket_id`, `customer_id`, `subject`, `body`, and `account_tier` — five fields that have no bearing on which clause fires and are only used in the body. With four clauses and seven extractions per head, a reader must carefully inspect each binding just to understand that dispatch is controlled by two of them. |

---

```elixir
defmodule Support.TicketRouter do
  @moduledoc """
  Routes incoming support tickets to the appropriate queue, team,
  and SLA tier. Handles escalation for critical issues and automated
  triage for common technical categories.
  """

  require Logger

  alias Support.{
    QueueManager,
    EscalationEngine,
    AutoResponder,
    SlaPolicy,
    TicketRepo,
    AuditLog,
    AgentNotifier
  }

  @critical_severity_threshold 80
  @high_severity_threshold 50

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `ticket_id`, `customer_id`, `subject`,
  # `body`, and `account_tier` are extracted in the function head of every
  # clause but none of them are used in pattern matching or guards. Only
  # `category` controls which clause is selected, and `severity_score` is used
  # in the guards. With four clauses, each carrying seven destructured bindings,
  # the reader is forced to mentally filter out five irrelevant bindings per
  # clause to identify the actual routing conditions.
  def route(%Support.Ticket{
        ticket_id: ticket_id,
        customer_id: customer_id,
        subject: subject,
        body: body,
        account_tier: account_tier,
        category: :billing,
        severity_score: severity_score
      })
      when severity_score >= @critical_severity_threshold do
    Logger.warning(
      "[TicketRouter] Critical billing ticket #{ticket_id} from #{customer_id} " <>
        "(tier: #{account_tier}, score: #{severity_score}): #{subject}"
    )

    sla = SlaPolicy.resolve(:billing, :critical, account_tier)

    with {:ok, case_id} <- EscalationEngine.open_case(ticket_id, :billing, :critical),
         {:ok, agent_id} <- QueueManager.assign_senior_agent(ticket_id, :billing),
         :ok <- TicketRepo.update_status(ticket_id, :escalated, %{case_id: case_id, sla: sla}),
         :ok <- AgentNotifier.alert_urgent(agent_id, ticket_id, subject),
         :ok <- AutoResponder.send_escalation_ack(customer_id, ticket_id, sla.response_minutes),
         :ok <- AuditLog.write(:ticket_escalated, customer_id, %{
                  ticket_id: ticket_id,
                  category: :billing,
                  severity_score: severity_score,
                  case_id: case_id,
                  body_length: byte_size(body)
                }) do
      {:ok, :escalated, case_id}
    else
      {:error, reason} ->
        Logger.error("[TicketRouter] Escalation failed for ticket #{ticket_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def route(%Support.Ticket{
        ticket_id: ticket_id,
        customer_id: customer_id,
        subject: subject,
        body: body,
        account_tier: account_tier,
        category: :billing,
        severity_score: severity_score
      })
      when severity_score < @critical_severity_threshold do
    Logger.info(
      "[TicketRouter] Routing standard billing ticket #{ticket_id} from #{customer_id} " <>
        "(tier: #{account_tier})"
    )

    sla = SlaPolicy.resolve(:billing, :standard, account_tier)

    with {:ok, queue_position} <- QueueManager.enqueue(ticket_id, :billing, account_tier),
         :ok <- TicketRepo.update_status(ticket_id, :queued, %{sla: sla, position: queue_position}),
         :ok <- AutoResponder.send_acknowledgement(customer_id, ticket_id, sla.response_minutes),
         :ok <- AuditLog.write(:ticket_queued, customer_id, %{
                  ticket_id: ticket_id,
                  category: :billing,
                  queue_position: queue_position,
                  subject_length: byte_size(subject),
                  body_length: byte_size(body)
                }) do
      {:ok, :queued, queue_position}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  def route(%Support.Ticket{
        ticket_id: ticket_id,
        customer_id: customer_id,
        subject: subject,
        body: body,
        account_tier: account_tier,
        category: :technical,
        severity_score: severity_score
      })
      when severity_score >= @high_severity_threshold do
    Logger.info(
      "[TicketRouter] High-severity technical ticket #{ticket_id} from #{customer_id} " <>
        "(score: #{severity_score})"
    )

    sla = SlaPolicy.resolve(:technical, :high, account_tier)

    suggested_articles = AutoResponder.suggest_kb_articles(subject, body, :technical)

    with :ok <- AutoResponder.send_technical_triage(customer_id, ticket_id, suggested_articles, sla),
         {:ok, queue_position} <- QueueManager.enqueue(ticket_id, :technical_high, account_tier),
         :ok <- TicketRepo.update_status(ticket_id, :triaged, %{sla: sla, position: queue_position}),
         :ok <- AuditLog.write(:ticket_triaged, customer_id, %{
                  ticket_id: ticket_id,
                  category: :technical,
                  severity_score: severity_score,
                  kb_articles: length(suggested_articles)
                }) do
      {:ok, :triaged, queue_position}
    else
      {:error, reason} ->
        Logger.error("[TicketRouter] Technical triage failed for #{ticket_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def route(%Support.Ticket{
        ticket_id: ticket_id,
        customer_id: customer_id,
        subject: subject,
        body: body,
        account_tier: _account_tier,
        category: :technical,
        severity_score: severity_score
      })
      when severity_score < @high_severity_threshold do
    Logger.info("[TicketRouter] Attempting auto-resolution for low-severity technical ticket #{ticket_id}")

    suggested_articles = AutoResponder.suggest_kb_articles(subject, body, :technical)
    confidence = AutoResponder.resolution_confidence(suggested_articles)

    if confidence >= 0.85 do
      with :ok <- AutoResponder.send_auto_resolution(customer_id, ticket_id, suggested_articles),
           :ok <- TicketRepo.update_status(ticket_id, :auto_resolved, %{confidence: confidence}),
           :ok <- AuditLog.write(:ticket_auto_resolved, customer_id, %{
                    ticket_id: ticket_id,
                    severity_score: severity_score,
                    confidence: confidence
                  }) do
        {:ok, :auto_resolved}
      end
    else
      QueueManager.enqueue(ticket_id, :technical_low, :standard)
      TicketRepo.update_status(ticket_id, :queued, %{})
      {:ok, :queued_low}
    end
  end
  # VALIDATION: SMELL END

  def route(%Support.Ticket{ticket_id: id, category: cat}) do
    Logger.error("[TicketRouter] No routing rule for category '#{cat}' on ticket #{id}")
    {:error, :unroutable_category}
  end
end
```
