```elixir
defmodule Support.Tickets.EscalationEngine do
  @moduledoc """
  Evaluates open support tickets against escalation policies and triggers
  appropriate escalation actions for breached SLA thresholds.

  Escalation checks are run periodically by a supervised scheduler and
  record each escalation event in the audit trail.
  """

  use GenServer, restart: :permanent

  alias Support.Tickets.{Ticket, EscalationPolicy, EscalationEvent, AssignmentRouter}
  alias Support.Repo
  import Ecto.Query, warn: false

  @check_interval_ms 120_000

  @doc """
  Starts the escalation engine under a supervisor.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers an immediate escalation evaluation cycle.
  """
  @spec run_now() :: :ok
  def run_now do
    GenServer.cast(__MODULE__, :evaluate)
  end

  @impl GenServer
  def init(opts) do
    policies = Keyword.get(opts, :policies, load_default_policies())
    schedule_check()
    {:ok, %{policies: policies}}
  end

  @impl GenServer
  def handle_cast(:evaluate, state) do
    evaluate_all(state.policies)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:scheduled_check, state) do
    evaluate_all(state.policies)
    schedule_check()
    {:noreply, state}
  end

  defp evaluate_all(policies) do
    open_tickets = load_open_tickets()
    Enum.each(open_tickets, &evaluate_ticket(&1, policies))
  end

  defp evaluate_ticket(ticket, policies) do
    matching_policy = find_matching_policy(ticket, policies)

    if matching_policy && sla_breached?(ticket, matching_policy) do
      trigger_escalation(ticket, matching_policy)
    end
  end

  defp find_matching_policy(ticket, policies) do
    Enum.find(policies, fn policy ->
      policy.priority == ticket.priority and
        policy.category == ticket.category
    end)
  end

  defp sla_breached?(%Ticket{opened_at: opened_at, escalated: false}, %EscalationPolicy{sla_minutes: sla}) do
    age_minutes = DateTime.diff(DateTime.utc_now(), opened_at, :minute)
    age_minutes >= sla
  end

  defp sla_breached?(_ticket, _policy), do: false

  defp trigger_escalation(ticket, policy) do
    Repo.transaction(fn ->
      with {:ok, assignee} <- AssignmentRouter.route_escalation(ticket, policy),
           {:ok, _event} <- record_escalation_event(ticket, assignee, policy),
           {:ok, _ticket} <- mark_escalated(ticket, assignee.id) do
        :ok
      else
        {:error, _reason} -> Repo.rollback(:escalation_failed)
      end
    end)
  end

  defp record_escalation_event(ticket, assignee, policy) do
    %EscalationEvent{}
    |> EscalationEvent.changeset(%{
      ticket_id: ticket.id,
      assigned_to_id: assignee.id,
      policy_id: policy.id,
      escalated_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  defp mark_escalated(ticket, assignee_id) do
    ticket
    |> Ticket.escalation_changeset(%{escalated: true, assigned_to_id: assignee_id})
    |> Repo.update()
  end

  defp load_open_tickets do
    Ticket
    |> where([t], t.status == :open and t.escalated == false)
    |> preload(:assignee)
    |> Repo.all()
  end

  defp load_default_policies, do: Repo.all(EscalationPolicy)

  defp schedule_check do
    Process.send_after(self(), :scheduled_check, @check_interval_ms)
  end
end
```
