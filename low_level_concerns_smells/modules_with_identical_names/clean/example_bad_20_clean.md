```elixir
# ── file: lib/support/ticket.ex ──────────────────────────────────────────────

defmodule Support.Ticket do
  @moduledoc """
  Handles creation and initial triage of customer support tickets.
  Integrates with the queue management and SLA enforcement systems.
  """

  alias Support.{
    Customer,
    Agent,
    QueueManager,
    SLAPolicy,
    AutoClassifier,
    Notifier,
    Repo
  }

  @valid_channels [:email, :chat, :phone, :web_form, :api]
  @valid_priorities [:low, :normal, :high, :urgent]

  @type t :: %__MODULE__{
          id: String.t(),
          reference: String.t(),
          customer_id: String.t(),
          agent_id: String.t() | nil,
          channel: atom(),
          subject: String.t(),
          body: String.t(),
          priority: atom(),
          category: String.t() | nil,
          tags: [String.t()],
          status: :new | :open | :pending | :on_hold | :resolved | :closed,
          sla_due_at: DateTime.t() | nil,
          escalated: boolean(),
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  defstruct [
    :id,
    :reference,
    :customer_id,
    :agent_id,
    :channel,
    :subject,
    :body,
    :sla_due_at,
    :category,
    :created_at,
    :updated_at,
    tags: [],
    priority: :normal,
    status: :new,
    escalated: false
  ]

  @spec open(map(), map()) :: {:ok, t()} | {:error, term()}
  def open(customer_attrs, ticket_attrs) do
    channel = Map.get(ticket_attrs, :channel, :web_form)
    priority = Map.get(ticket_attrs, :priority, :normal)

    with {:ok, customer} <- Customer.resolve(customer_attrs),
         :ok <- validate_channel(channel),
         :ok <- validate_priority(priority),
         {:ok, category} <- AutoClassifier.classify(ticket_attrs[:subject], ticket_attrs[:body]),
         {:ok, sla} <- SLAPolicy.compute(customer, priority, category) do
      now = DateTime.utc_now()

      ticket = %__MODULE__{
        id: generate_id(),
        reference: generate_reference(),
        customer_id: customer.id,
        channel: channel,
        subject: ticket_attrs[:subject],
        body: ticket_attrs[:body],
        priority: priority,
        category: category,
        tags: ticket_attrs[:tags] || [],
        sla_due_at: sla.due_at,
        status: :new,
        created_at: now,
        updated_at: now
      }

      Repo.insert(:tickets, ticket)
      QueueManager.enqueue(ticket)
      Notifier.send_acknowledgement(ticket, customer)

      {:ok, ticket}
    end
  end

  @spec assign(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def assign(ticket_id, agent_id) do
    with {:ok, ticket} <- Repo.fetch(:tickets, ticket_id),
         {:ok, _agent} <- Agent.fetch(agent_id) do
      updated = Repo.update(:tickets, ticket_id, %{
        agent_id: agent_id,
        status: :open,
        updated_at: DateTime.utc_now()
      })

      {:ok, updated}
    end
  end

  @spec close(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def close(ticket_id, resolution_note) do
    with {:ok, ticket} <- Repo.fetch(:tickets, ticket_id),
         :ok <- validate_closeable(ticket) do
      updated = Repo.update(:tickets, ticket_id, %{
        status: :closed,
        resolution_note: resolution_note,
        closed_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      })

      Notifier.send_resolution(updated)
      {:ok, updated}
    end
  end

  defp validate_channel(c) when c in @valid_channels, do: :ok
  defp validate_channel(_), do: {:error, :invalid_channel}

  defp validate_priority(p) when p in @valid_priorities, do: :ok
  defp validate_priority(_), do: {:error, :invalid_priority}

  defp validate_closeable(%{status: s}) when s in [:open, :pending, :on_hold], do: :ok
  defp validate_closeable(_), do: {:error, :ticket_not_closeable}

  defp generate_id, do: :crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)
  defp generate_reference, do: "TKT-" <> :crypto.strong_rand_bytes(4) |> Base.encode16()
end


# ── file: lib/support/ticket_escalation.ex ───────────────────────────────────

defmodule Support.Ticket do
  @moduledoc """
  Handles ticket escalation to senior agents and management.
  Enforces SLA breach escalation rules and VIP customer fast-tracking.
  """

  alias Support.{Agent, Notifier, SLAPolicy, Repo, AuditLog}

  @escalation_levels [:tier2, :tier3, :management, :executive]
  @sla_breach_threshold_minutes 30

  @spec escalate(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def escalate(ticket_id, opts \\ %{}) do
    target_level = Map.get(opts, :level, :tier2)
    reason = Map.get(opts, :reason, :sla_at_risk)

    with {:ok, ticket} <- Repo.fetch(:tickets, ticket_id),
         :ok <- validate_escalatable(ticket),
         :ok <- validate_level(target_level),
         {:ok, escalation_agent} <- Agent.find_available(target_level) do
      updated = Repo.update(:tickets, ticket_id, %{
        agent_id: escalation_agent.id,
        priority: bump_priority(ticket.priority),
        escalated: true,
        escalated_at: DateTime.utc_now(),
        escalation_level: target_level,
        escalation_reason: reason,
        status: :open,
        updated_at: DateTime.utc_now()
      })

      Notifier.notify_escalation(updated, escalation_agent, reason)
      Notifier.notify_customer_escalated(ticket.customer_id, updated)

      AuditLog.write(:ticket_escalated, %{
        ticket_id: ticket_id,
        level: target_level,
        reason: reason,
        new_agent_id: escalation_agent.id
      })

      {:ok, updated}
    end
  end

  @spec check_sla_breaches() :: {:ok, non_neg_integer()}
  def check_sla_breaches do
    now = DateTime.utc_now()
    threshold = DateTime.add(now, @sla_breach_threshold_minutes * 60, :second)

    at_risk =
      Repo.all(:tickets,
        status: [:new, :open, :pending],
        sla_due_at_before: threshold,
        escalated: false
      )

    Enum.each(at_risk, fn ticket ->
      escalate(ticket.id, %{reason: :sla_breach_imminent, level: :tier2})
    end)

    {:ok, length(at_risk)}
  end

  @spec deescalate(String.t()) :: {:ok, map()} | {:error, term()}
  def deescalate(ticket_id) do
    with {:ok, ticket} <- Repo.fetch(:tickets, ticket_id),
         :ok <- validate_escalated(ticket) do
      updated = Repo.update(:tickets, ticket_id, %{
        escalated: false,
        escalation_level: nil,
        updated_at: DateTime.utc_now()
      })

      {:ok, updated}
    end
  end

  defp validate_escalatable(%{status: s}) when s in [:new, :open, :pending], do: :ok
  defp validate_escalatable(_), do: {:error, :ticket_not_escalatable}

  defp validate_escalated(%{escalated: true}), do: :ok
  defp validate_escalated(_), do: {:error, :ticket_not_escalated}

  defp validate_level(l) when l in @escalation_levels, do: :ok
  defp validate_level(_), do: {:error, :invalid_escalation_level}

  defp bump_priority(:low), do: :normal
  defp bump_priority(:normal), do: :high
  defp bump_priority(:high), do: :urgent
  defp bump_priority(:urgent), do: :urgent
end
```
