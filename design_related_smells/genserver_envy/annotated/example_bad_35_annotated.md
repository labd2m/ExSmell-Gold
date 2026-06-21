# Annotated Example — GenServer Envy

- **Smell name:** GenServer Envy
- **Expected smell location:** `ModerationQueueAgent` module — `Agent` managing content moderation workflows
- **Affected function(s):** `submit_for_review/2`, `assign_reviewer/2`, `record_decision/3`
- **Short explanation:** Moderation workflows involve reviewer assignment algorithms, decision enforcement, escalation routing, and notification dispatch — coordinated orchestration that an `Agent` is not designed to perform.

```elixir
defmodule MyApp.ModerationQueueAgent do
  @moduledoc """
  Manages content moderation workflows — queuing submitted content,
  assigning reviewers, recording decisions, and handling escalations.
  """

  use Agent

  alias MyApp.{Repo, Mailer, AuditLog, ReviewerPool}
  alias MyApp.Moderation.{ModerationCase, ReviewDecision, EscalationRecord}

  @escalation_after_hours 24
  @auto_approve_score_threshold 0.95

  def start_link(_opts) do
    cases = Repo.all(ModerationCase) |> Enum.into(%{}, &{&1.id, &1})
    Agent.start_link(fn -> %{cases: cases, reviewer_load: %{}} end, name: __MODULE__)
  end

  def get_case(case_id) do
    Agent.get(__MODULE__, fn state -> Map.get(state.cases, case_id) end)
  end

  def queue_depth do
    Agent.get(__MODULE__, fn state ->
      Enum.count(state.cases, fn {_, c} -> c.status == :pending end)
    end)
  end

  # VALIDATION: SMELL START - GenServer Envy
  # VALIDATION: This is a smell because the Agent implements a full content
  # moderation orchestration system: it applies auto-approval rules based on
  # ML scores, queries a reviewer pool to balance workload, persists decisions
  # with evidence attachments, handles escalation logic with time comparisons,
  # and sends email notifications at each step. This multi-step, side-effectful
  # workflow management is the responsibility of a GenServer, not an Agent
  # whose purpose is simply to share state between processes.

  def submit_for_review(content_ref, ml_score) do
    Agent.get_and_update(__MODULE__, fn state ->
      if ml_score >= @auto_approve_score_threshold do
        mod_case = %ModerationCase{
          id: Ecto.UUID.generate(),
          content_ref: content_ref,
          ml_score: ml_score,
          status: :auto_approved,
          submitted_at: DateTime.utc_now(),
          decided_at: DateTime.utc_now(),
          reviewer_id: nil
        }

        Repo.insert!(mod_case)
        AuditLog.record(:content_auto_approved, %{ref: content_ref, score: ml_score})
        {{:ok, {:auto_approved, mod_case}}, put_in(state, [:cases, mod_case.id], mod_case)}
      else
        reviewer_id = ReviewerPool.least_loaded(state.reviewer_load)

        mod_case = %ModerationCase{
          id: Ecto.UUID.generate(),
          content_ref: content_ref,
          ml_score: ml_score,
          status: :pending,
          reviewer_id: reviewer_id,
          submitted_at: DateTime.utc_now(),
          decided_at: nil
        }

        Repo.insert!(mod_case)
        Mailer.notify_reviewer_new_case(reviewer_id, mod_case.id)
        AuditLog.record(:case_queued, %{case_id: mod_case.id, reviewer: reviewer_id})

        new_load = Map.update(state.reviewer_load, reviewer_id, 1, &(&1 + 1))
        new_state = %{state | cases: Map.put(state.cases, mod_case.id, mod_case), reviewer_load: new_load}
        {{:ok, {:queued, mod_case}}, new_state}
      end
    end)
  end

  def assign_reviewer(case_id, reviewer_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      with {:ok, mod_case} <- Map.fetch(state.cases, case_id),
           :pending <- mod_case.status do
        old_reviewer = mod_case.reviewer_id
        updated_case = %{mod_case | reviewer_id: reviewer_id}
        Repo.update!(updated_case)
        Mailer.notify_reviewer_new_case(reviewer_id, case_id)
        AuditLog.record(:reviewer_reassigned, %{case_id: case_id, from: old_reviewer, to: reviewer_id})

        new_load =
          state.reviewer_load
          |> Map.update(old_reviewer, 0, &max(0, &1 - 1))
          |> Map.update(reviewer_id, 1, &(&1 + 1))

        new_state = %{
          state
          | cases: Map.put(state.cases, case_id, updated_case),
            reviewer_load: new_load
        }

        {{:ok, updated_case}, new_state}
      else
        :error -> {{:error, :case_not_found}, state}
        status -> {{:error, {:wrong_status, status}}, state}
      end
    end)
  end

  def record_decision(case_id, reviewer_id, decision) when decision in [:approved, :rejected, :escalated] do
    Agent.get_and_update(__MODULE__, fn state ->
      with {:ok, mod_case} <- Map.fetch(state.cases, case_id),
           :pending <- mod_case.status,
           true <- mod_case.reviewer_id == reviewer_id do
        decided_case = %{mod_case | status: decision, decided_at: DateTime.utc_now()}
        Repo.update!(decided_case)
        AuditLog.record(:case_decided, %{case_id: case_id, decision: decision, by: reviewer_id})

        if decision == :escalated do
          senior = ReviewerPool.pick_senior()
          escalation = %EscalationRecord{case_id: case_id, escalated_to: senior, escalated_at: DateTime.utc_now()}
          Repo.insert!(escalation)
          Mailer.notify_escalation(senior, case_id)
        end

        new_load = Map.update(state.reviewer_load, reviewer_id, 0, &max(0, &1 - 1))
        new_state = %{
          state
          | cases: Map.put(state.cases, case_id, decided_case),
            reviewer_load: new_load
        }

        {{:ok, decided_case}, new_state}
      else
        :error -> {{:error, :not_found}, state}
        status when is_atom(status) -> {{:error, {:wrong_status, status}}, state}
        false -> {{:error, :not_assigned_reviewer}, state}
      end
    end)
  end

  def escalate_stale_cases do
    cutoff = DateTime.add(DateTime.utc_now(), -@escalation_after_hours * 3_600, :second)

    Agent.update(__MODULE__, fn state ->
      stale_cases =
        state.cases
        |> Map.values()
        |> Enum.filter(fn c ->
          c.status == :pending and DateTime.compare(c.submitted_at, cutoff) == :lt
        end)

      Enum.reduce(stale_cases, state, fn mod_case, acc_state ->
        senior = ReviewerPool.pick_senior()
        updated = %{mod_case | reviewer_id: senior}
        Repo.update!(updated)
        Mailer.notify_escalation(senior, mod_case.id)
        AuditLog.record(:case_stale_escalated, %{case_id: mod_case.id})
        put_in(acc_state, [:cases, mod_case.id], updated)
      end)
    end)
  end

  # VALIDATION: SMELL END
end
```
