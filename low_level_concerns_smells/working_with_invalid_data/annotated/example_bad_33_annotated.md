# Code Smell Annotation

- **Smell name:** Working with invalid data
- **Expected smell location:** `SLATracker.open_ticket/3`, where `sla_hours` is passed to `DateTime.add/3`
- **Affected function(s):** `open_ticket/3`
- **Short explanation:** The `sla_hours` value is pulled from the SLA policy record and passed directly to `DateTime.add/3` without verifying it is an integer. SLA policy records are often loaded from configuration files or external APIs where numeric fields may arrive as floats or strings. Passing `12.0` or `"12"` causes a `FunctionClauseError` inside the DateTime module, with no reference to the `open_ticket/3` boundary where the invalid data was first used.

```elixir
defmodule MyApp.Support.SLATracker do
  @moduledoc """
  Manages service level agreement tracking for customer support tickets.
  Monitors first-response and resolution deadlines, escalates breaches,
  and generates SLA compliance reports.
  """

  require Logger

  alias MyApp.Support.{TicketRecord, SLAPolicy, EscalationEngine, SLABreachLog}
  alias MyApp.Notifications.AlertDispatcher

  @check_interval_ms 60_000
  @warning_threshold_percent 0.80
  @supported_priorities [:low, :normal, :high, :critical]

  @type sla_opts :: [
          policy_id: String.t() | nil,
          created_at: DateTime.t(),
          tags: [String.t()]
        ]

  @spec open_ticket(String.t(), atom(), sla_opts()) ::
          {:ok, TicketRecord.t()} | {:error, atom()}
  def open_ticket(customer_id, priority, opts \\ []) do
    policy_id = Keyword.get(opts, :policy_id)
    created_at = Keyword.get(opts, :created_at, DateTime.utc_now())
    tags = Keyword.get(opts, :tags, [])

    with :ok <- validate_priority(priority),
         {:ok, policy} <- resolve_policy(policy_id, customer_id, priority) do

      # VALIDATION: SMELL START - Working with invalid data
      # VALIDATION: This is a smell because `policy.first_response_hours` and
      # VALIDATION: `policy.resolution_hours` are pulled from the policy struct and
      # VALIDATION: passed directly to `DateTime.add/3` without type validation.
      # VALIDATION: If the policy record was loaded from a JSON config where hours
      # VALIDATION: are stored as floats (e.g. 4.0), the FunctionClauseError will
      # VALIDATION: fire inside DateTime with no indication the source was here.
      first_response_deadline =
        DateTime.add(created_at, policy.first_response_hours * 3600, :second)

      resolution_deadline =
        DateTime.add(created_at, policy.resolution_hours * 3600, :second)
      # VALIDATION: SMELL END

      ticket_attrs = %{
        id: Ecto.UUID.generate(),
        customer_id: customer_id,
        priority: priority,
        policy_id: policy.id,
        status: :open,
        tags: tags,
        first_response_deadline: first_response_deadline,
        resolution_deadline: resolution_deadline,
        created_at: created_at,
        sla_status: :within_sla
      }

      with {:ok, ticket} <- TicketRecord.create(ticket_attrs) do
        schedule_deadline_checks(ticket)

        Logger.info(
          "Ticket opened: #{ticket.id} customer=#{customer_id} priority=#{priority} " <>
            "resolution_deadline=#{resolution_deadline}"
        )

        {:ok, ticket}
      end
    end
  end

  @spec record_first_response(String.t(), String.t()) ::
          {:ok, TicketRecord.t()} | {:error, atom()}
  def record_first_response(ticket_id, responder_id) do
    with {:ok, ticket} <- TicketRecord.fetch(ticket_id),
         :ok <- check_not_already_responded(ticket) do
      responded_at = DateTime.utc_now()

      sla_met =
        DateTime.compare(responded_at, ticket.first_response_deadline) == :lt

      updates = %{
        first_responded_at: responded_at,
        first_responded_by: responder_id,
        first_response_sla_met: sla_met
      }

      unless sla_met do
        breach_seconds = DateTime.diff(responded_at, ticket.first_response_deadline)
        SLABreachLog.record(ticket_id, :first_response, breach_seconds)
        Logger.warning("First response SLA breached: ticket=#{ticket_id} by #{breach_seconds}s")
      end

      TicketRecord.update(ticket_id, updates)
    end
  end

  @spec close_ticket(String.t(), String.t()) :: {:ok, TicketRecord.t()} | {:error, atom()}
  def close_ticket(ticket_id, closed_by_id) do
    with {:ok, ticket} <- TicketRecord.fetch(ticket_id) do
      closed_at = DateTime.utc_now()
      resolution_sla_met = DateTime.compare(closed_at, ticket.resolution_deadline) == :lt

      unless resolution_sla_met do
        breach_seconds = DateTime.diff(closed_at, ticket.resolution_deadline)
        SLABreachLog.record(ticket_id, :resolution, breach_seconds)
      end

      TicketRecord.update(ticket_id, %{
        status: :closed,
        closed_at: closed_at,
        closed_by_id: closed_by_id,
        resolution_sla_met: resolution_sla_met
      })
    end
  end

  @spec compliance_report(Date.t(), Date.t()) :: {:ok, map()}
  def compliance_report(date_from, date_to) do
    with {:ok, tickets} <- TicketRecord.fetch_range(date_from, date_to) do
      total = length(tickets)
      response_met = Enum.count(tickets, & &1.first_response_sla_met)
      resolution_met = Enum.count(tickets, & &1.resolution_sla_met)

      {:ok,
       %{
         period: %{from: date_from, to: date_to},
         total_tickets: total,
         first_response_compliance: safe_percent(response_met, total),
         resolution_compliance: safe_percent(resolution_met, total)
       }}
    end
  end

  # Private helpers

  defp validate_priority(p) when p in @supported_priorities, do: :ok
  defp validate_priority(_), do: {:error, :invalid_priority}

  defp resolve_policy(nil, customer_id, priority) do
    SLAPolicy.default_for(customer_id, priority)
  end

  defp resolve_policy(policy_id, _customer_id, _priority) do
    SLAPolicy.fetch(policy_id)
  end

  defp check_not_already_responded(%{first_responded_at: nil}), do: :ok
  defp check_not_already_responded(_), do: {:error, :already_responded}

  defp schedule_deadline_checks(ticket) do
    warning_offset =
      trunc(DateTime.diff(ticket.resolution_deadline, ticket.created_at) * @warning_threshold_percent)

    warn_at = DateTime.add(ticket.created_at, warning_offset, :second)
    Logger.debug("SLA warning check scheduled at #{warn_at} for ticket #{ticket.id}")
  end

  defp safe_percent(_, 0), do: 0.0
  defp safe_percent(count, total), do: Float.round(count / total * 100, 1)
end
```
