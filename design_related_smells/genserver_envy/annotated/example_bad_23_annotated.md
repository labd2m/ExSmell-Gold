# Annotated Example — GenServer Envy

- **Smell name:** GenServer Envy
- **Expected smell location:** `SLAMonitorAgent` module — `Agent` executing SLA evaluation and alerting workflows
- **Affected function(s):** `record_event/3`, `evaluate_breach/2`, `escalate/2`
- **Short explanation:** SLA monitoring involves time calculations, threshold evaluation, tiered escalation logic, and external alert dispatch — server-side orchestration that exceeds an `Agent`'s state-sharing purpose.

```elixir
defmodule MyApp.SLAMonitorAgent do
  @moduledoc """
  Monitors service-level agreement compliance for support tickets,
  detects breaches, and triggers tiered escalation workflows.
  """

  use Agent

  alias MyApp.{AlertService, Repo, Mailer}
  alias MyApp.SLA.{Policy, TicketSLA, BreachEvent, EscalationRecord}

  @tier_thresholds %{
    response: [warn: 0.75, breach: 1.0],
    resolution: [warn: 0.80, breach: 1.0]
  }

  def start_link(_opts) do
    policies = Repo.all(Policy) |> Enum.into(%{}, &{&1.tier, &1})
    Agent.start_link(fn -> %{policies: policies, ticket_slas: %{}, breaches: []} end,
      name: __MODULE__)
  end

  def get_ticket_sla(ticket_id) do
    Agent.get(__MODULE__, fn state -> Map.get(state.ticket_slas, ticket_id) end)
  end

  def open_ticket_sla(ticket_id, tier, opened_at) do
    Agent.update(__MODULE__, fn state ->
      policy = Map.fetch!(state.policies, tier)

      sla = %TicketSLA{
        ticket_id: ticket_id,
        tier: tier,
        opened_at: opened_at,
        response_deadline: DateTime.add(opened_at, policy.response_seconds, :second),
        resolution_deadline: DateTime.add(opened_at, policy.resolution_seconds, :second),
        first_response_at: nil,
        resolved_at: nil,
        escalation_level: 0
      }

      put_in(state, [:ticket_slas, ticket_id], sla)
    end)
  end

  # VALIDATION: SMELL START - GenServer Envy
  # VALIDATION: This is a smell because the Agent implements multi-step SLA
  # evaluation logic: it computes time-to-deadline ratios, compares against
  # tiered thresholds, fires external alerts, sends escalation emails, and
  # persists breach records. This coordinated, side-effectful orchestration
  # belongs in a GenServer rather than an Agent, which should only provide
  # shared access to state.

  def record_event(ticket_id, event_type, occurred_at) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.ticket_slas, ticket_id) do
        :error ->
          {{:error, :ticket_not_found}, state}

        {:ok, sla} ->
          updated_sla =
            case event_type do
              :first_response ->
                %{sla | first_response_at: occurred_at}

              :resolved ->
                %{sla | resolved_at: occurred_at}

              _ ->
                sla
            end

          new_state = put_in(state, [:ticket_slas, ticket_id], updated_sla)
          {{:ok, updated_sla}, new_state}
      end
    end)
  end

  def evaluate_breach(ticket_id, now \\ DateTime.utc_now()) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.ticket_slas, ticket_id) do
        :error ->
          {{:error, :ticket_not_found}, state}

        {:ok, sla} ->
          response_pct =
            if sla.first_response_at do
              1.0
            else
              elapsed = DateTime.diff(now, sla.opened_at, :second)
              window = DateTime.diff(sla.response_deadline, sla.opened_at, :second)
              elapsed / max(window, 1)
            end

          resolution_pct =
            if sla.resolved_at do
              1.0
            else
              elapsed = DateTime.diff(now, sla.opened_at, :second)
              window = DateTime.diff(sla.resolution_deadline, sla.opened_at, :second)
              elapsed / max(window, 1)
            end

          response_status = classify(response_pct, @tier_thresholds.response)
          resolution_status = classify(resolution_pct, @tier_thresholds.resolution)

          {new_breaches, updated_sla} =
            handle_statuses(sla, response_status, resolution_status, now)

          Enum.each(new_breaches, fn breach ->
            Repo.insert!(breach)
            AlertService.notify(:sla_breach, %{ticket_id: ticket_id, type: breach.breach_type})
          end)

          new_state = %{
            state
            | ticket_slas: Map.put(state.ticket_slas, ticket_id, updated_sla),
              breaches: new_breaches ++ state.breaches
          }

          {{:ok, %{response: response_status, resolution: resolution_status}}, new_state}
      end
    end)
  end

  def escalate(ticket_id, escalated_by) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.ticket_slas, ticket_id) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, sla} ->
          new_level = sla.escalation_level + 1
          updated_sla = %{sla | escalation_level: new_level}

          record = %EscalationRecord{
            ticket_id: ticket_id,
            level: new_level,
            escalated_by: escalated_by,
            escalated_at: DateTime.utc_now()
          }

          Repo.insert!(record)

          policy = Map.get(state.policies, sla.tier)
          recipient = Enum.at(policy.escalation_contacts, new_level - 1)

          if recipient do
            Mailer.deliver_escalation_notice(recipient, ticket_id, new_level)
          end

          new_state = put_in(state, [:ticket_slas, ticket_id], updated_sla)
          {{:ok, record}, new_state}
      end
    end)
  end

  # VALIDATION: SMELL END

  defp classify(pct, thresholds) do
    cond do
      pct >= thresholds[:breach] -> :breached
      pct >= thresholds[:warn] -> :warning
      true -> :on_track
    end
  end

  defp handle_statuses(sla, response_status, resolution_status, now) do
    breaches = []

    breaches =
      if response_status == :breached and :response_breach not in sla.recorded_breaches do
        [
          %BreachEvent{
            id: Ecto.UUID.generate(),
            ticket_id: sla.ticket_id,
            breach_type: :response_breach,
            breached_at: now
          }
          | breaches
        ]
      else
        breaches
      end

    breaches =
      if resolution_status == :breached and :resolution_breach not in sla.recorded_breaches do
        [
          %BreachEvent{
            id: Ecto.UUID.generate(),
            ticket_id: sla.ticket_id,
            breach_type: :resolution_breach,
            breached_at: now
          }
          | breaches
        ]
      else
        breaches
      end

    new_recorded = Enum.map(breaches, & &1.breach_type)
    updated_sla = %{sla | recorded_breaches: sla.recorded_breaches ++ new_recorded}
    {breaches, updated_sla}
  end
end
```
