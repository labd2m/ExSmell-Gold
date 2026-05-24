```elixir
defmodule MyApp.Support.EscalationEngine do
  @moduledoc """
  Evaluates open tickets against SLA rules and routes qualifying tickets
  to senior agents or specialist queues for escalation.
  """

  alias MyApp.Support.{SupportTicket, AgentPool, EscalationRecord}
  alias MyApp.Notifications.EscalationMailer

  @sentiment_escalation_threshold -0.4
  @reopen_escalation_threshold 2

  def escalate(ticket_id) do
    with {:ok, ticket} <- SupportTicket.fetch(ticket_id),
         {:ok, pool}   <- AgentPool.for_tier(:tier2) do

      sla_tier         = ticket.sla_tier
      reopen_count     = ticket.reopened_count
      sentiment        = ticket.customer_sentiment_score

      available_agents = pool.available_agent_ids
      escalation_queue = pool.escalation_queue
      max_concurrent   = pool.max_concurrent

      reason =
        cond do
          sla_tier == :critical                        -> :critical_sla
          reopen_count >= @reopen_escalation_threshold -> :repeated_reopen
          sentiment <= @sentiment_escalation_threshold -> :negative_sentiment
          true                                         -> nil
        end

      if is_nil(reason) do
        {:ok, :no_escalation_needed}
      else
        queue_length = length(escalation_queue)

        cond do
          available_agents == [] and queue_length >= max_concurrent ->
            {:error, :escalation_queue_full}

          available_agents == [] ->
            enqueue_for_escalation(ticket, reason, pool)

          true ->
            agent_id = List.first(available_agents)
            assign_escalation(ticket, agent_id, reason)
        end
      end
    end
  end

  def auto_escalate_overdue do
    overdue = SupportTicket.list_overdue_sla()
    Enum.map(overdue, fn ticket ->
      case escalate(ticket.id) do
        {:ok, :no_escalation_needed} -> :skipped
        {:ok, record}                -> {:escalated, record.id}
        {:error, reason}             -> {:failed, reason}
      end
    end)
  end

  def resolve_escalation(record_id, resolution_notes) do
    case EscalationRecord.fetch(record_id) do
      nil    -> {:error, :not_found}
      record ->
        updated = %{record |
          status:           :resolved,
          resolution_notes: resolution_notes,
          resolved_at:      DateTime.utc_now()
        }
        EscalationRecord.save(updated)
        SupportTicket.update_status(record.ticket_id, :resolved)
        {:ok, updated}
    end
  end

  def list_open_escalations(opts \\ []) do
    tier = Keyword.get(opts, :tier)
    :ets.tab2list(:escalation_records)
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(&1.status == :open))
    |> then(fn records ->
      if tier, do: Enum.filter(records, &(&1.tier == tier)), else: records
    end)
    |> Enum.sort_by(& &1.created_at)
  end


  defp assign_escalation(ticket, agent_id, reason) do
    record = build_record(ticket, agent_id, reason, :open)
    EscalationRecord.save(record)
    SupportTicket.update_assignee(ticket.id, agent_id)
    EscalationMailer.notify_agent(agent_id, record)
    {:ok, record}
  end

  defp enqueue_for_escalation(ticket, reason, _pool) do
    record = build_record(ticket, nil, reason, :queued)
    EscalationRecord.save(record)
    {:ok, record}
  end

  defp build_record(ticket, agent_id, reason, status) do
    %{
      id:         generate_id(),
      ticket_id:  ticket.id,
      agent_id:   agent_id,
      reason:     reason,
      tier:       :tier2,
      status:     status,
      created_at: DateTime.utc_now()
    }
  end

  defp generate_id do
    "ESC-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
