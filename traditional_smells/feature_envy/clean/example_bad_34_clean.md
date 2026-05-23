```elixir
defmodule Support.SupportTicket do
  @moduledoc "Represents an open customer support ticket."

  defstruct [
    :id,
    :customer_id,
    :customer_tier,
    :subject,
    :category,
    :status,
    :severity,
    :opened_at,
    :last_replied_at,
    :sla_breach_count,
    :blocking_deployment,
    :assigned_to,
    :channel
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      customer_id: "CUST-5510",
      customer_tier: :enterprise,
      subject: "Authentication service returning 503",
      category: :incident,
      status: :open,
      severity: :high,
      opened_at: ~U[2024-03-14 06:00:00Z],
      last_replied_at: ~U[2024-03-14 07:30:00Z],
      sla_breach_count: 1,
      blocking_deployment: true,
      assigned_to: nil,
      channel: :email
    }
  end

  def hours_open(%__MODULE__{opened_at: opened}) do
    DateTime.diff(DateTime.utc_now(), opened, :second) / 3600
  end

  def customer_tier(%__MODULE__{customer_tier: tier}), do: tier

  def is_blocking?(%__MODULE__{blocking_deployment: true}), do: true
  def is_blocking?(_), do: false

  def breach_count(%__MODULE__{sla_breach_count: n}), do: n

  def unassigned?(%__MODULE__{assigned_to: nil}), do: true
  def unassigned?(_), do: false

  def ticket_summary(%__MODULE__{id: id, subject: subj, severity: sev}) do
    "[#{id}] #{subj} (#{sev})"
  end
end

defmodule Support.EscalationManager do
  @moduledoc """
  Manages ticket escalation workflows, computing priority levels and
  routing tickets to the appropriate support tier.
  """

  alias Support.SupportTicket
  require Logger

  @doc """
  Runs escalation checks across all open ticket IDs and returns
  a list of escalation actions to be applied.
  """
  def run_escalation_sweep(ticket_ids) do
    ticket_ids
    |> Enum.map(fn id ->
      priority = determine_priority(id)
      ticket   = SupportTicket.get!(id)

      if priority in [:critical, :high] and SupportTicket.unassigned?(ticket) do
        Logger.warning("Unassigned high-priority ticket: #{SupportTicket.ticket_summary(ticket)}")
        {id, priority, :needs_assignment}
      else
        {id, priority, :ok}
      end
    end)
  end

  @doc "Routes a ticket to a support engineer based on current priority."
  def route(ticket_id, engineer_id) do
    Logger.info("Routing ticket #{ticket_id} to engineer #{engineer_id}")
    {:ok, :routed}
  end

  defp determine_priority(ticket_id) do
    ticket   = SupportTicket.get!(ticket_id)
    hours    = SupportTicket.hours_open(ticket)
    tier     = SupportTicket.customer_tier(ticket)
    blocking = SupportTicket.is_blocking?(ticket)
    breaches = SupportTicket.breach_count(ticket)

    score =
      0
      |> then(fn s -> if tier == :enterprise, do: s + 3, else: s end)
      |> then(fn s -> if tier == :growth,     do: s + 1, else: s end)
      |> then(fn s -> if blocking,            do: s + 4, else: s end)
      |> then(fn s -> s + breaches * 2 end)
      |> then(fn s -> if hours > 24, do: s + 2, else: s end)
      |> then(fn s -> if hours > 8,  do: s + 1, else: s end)

    cond do
      score >= 8 -> :critical
      score >= 5 -> :high
      score >= 3 -> :medium
      true       -> :low
    end
  end
end
```
