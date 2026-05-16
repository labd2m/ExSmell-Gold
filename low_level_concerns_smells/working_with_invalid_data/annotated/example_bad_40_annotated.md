# Example 40: Clinical Trial Patient Dosage Tracker - Annotated

## Metadata
- **Smell Name**: Working with invalid data
- **Expected Location**: `ClinicalTrial.DosageTracker.record_administration/4` function
- **Affected Functions**: `record_administration/4`
- **Explanation**: The function does not validate that `dose_amount` is a number before passing it to `:erlang.>=/2` via the `>=` guard-style comparison and subsequent multiplication. If a non-numeric value is provided, the error will surface inside the arithmetic expression rather than at the public boundary.

## Code

```elixir
defmodule ClinicalTrial.DosageTracker do
  @moduledoc """
  Tracks drug administration events for enrolled clinical trial participants,
  enforcing protocol dosage windows, cumulative limits, and safety flags.
  """

  alias ClinicalTrial.{Participant, AdministrationRecord, Protocol, SafetyAlert, AuditLog}

  @audit_category :dosage_event

  def enroll_participant(trial_id, participant_id, protocol_id) do
    with {:ok, trial} <- ClinicalTrial.get(trial_id),
         {:ok, participant} <- Participant.get(participant_id),
         {:ok, protocol} <- Protocol.get(protocol_id),
         :ok <- validate_eligibility(participant, protocol) do

      enrollment = %{
        trial_id: trial_id,
        participant_id: participant_id,
        protocol_id: protocol_id,
        status: :active,
        enrolled_at: DateTime.utc_now(),
        cumulative_dose: 0.0
      }

      {:ok, _} = Participant.enroll(enrollment)
      {:ok, _} = AuditLog.record(@audit_category, :enrolled, participant_id, %{trial_id: trial_id})

      {:ok, enrollment}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # VALIDATION: SMELL START - Working with invalid data
  # VALIDATION: This is a smell because `dose_amount` is not validated to be a
  # VALIDATION: number before being used in comparisons and arithmetic below.
  # VALIDATION: Passing a binary like "50.0" or an atom like :standard_dose
  # VALIDATION: will produce a confusing ArithmeticError or BadArg error inside
  # VALIDATION: this function's body rather than a clean boundary error message.
  def record_administration(participant_id, trial_id, dose_amount, administered_at) do
    with {:ok, participant} <- Participant.get(participant_id),
         {:ok, enrollment} <- Participant.get_enrollment(participant_id, trial_id),
         {:ok, protocol} <- Protocol.get(enrollment.protocol_id),
         :ok <- validate_enrollment_active(enrollment) do

      # No validation that dose_amount is numeric before arithmetic
      new_cumulative = enrollment.cumulative_dose + dose_amount

      within_session_limit = dose_amount <= protocol.max_single_dose
      within_cumulative_limit = new_cumulative <= protocol.max_cumulative_dose
      dose_interval_ok = check_dose_interval(participant_id, trial_id, protocol.min_interval_hours, administered_at)

      record = %AdministrationRecord{
        id: generate_record_id(),
        participant_id: participant_id,
        trial_id: trial_id,
        protocol_id: enrollment.protocol_id,
        dose_amount: dose_amount,
        dose_unit: protocol.dose_unit,
        administered_at: administered_at,
        within_session_limit: within_session_limit,
        within_cumulative_limit: within_cumulative_limit,
        flagged: not (within_session_limit and within_cumulative_limit and dose_interval_ok),
        recorded_at: DateTime.utc_now()
      }

      {:ok, _} = AdministrationRecord.insert(record)
      {:ok, _} = Participant.update_enrollment(participant_id, trial_id, %{cumulative_dose: new_cumulative})
      {:ok, _} = AuditLog.record(@audit_category, :administration_recorded, participant_id, %{dose: dose_amount})

      if record.flagged do
        issue_safety_alert(record, protocol, participant)
      end

      {:ok, record}
    else
      {:error, reason} -> {:error, reason}
    end
  end
  # VALIDATION: SMELL END

  def get_participant_dosage_history(participant_id, trial_id) do
    with {:ok, participant} <- Participant.get(participant_id),
         {:ok, enrollment} <- Participant.get_enrollment(participant_id, trial_id),
         {:ok, protocol} <- Protocol.get(enrollment.protocol_id),
         {:ok, records} <- AdministrationRecord.list_for_participant(participant_id, trial_id) do

      summary = %{
        participant_id: participant_id,
        trial_id: trial_id,
        protocol_id: enrollment.protocol_id,
        cumulative_dose: enrollment.cumulative_dose,
        max_cumulative_allowed: protocol.max_cumulative_dose,
        percent_used: Float.round(enrollment.cumulative_dose / protocol.max_cumulative_dose * 100, 1),
        administration_count: length(records),
        flagged_events: Enum.count(records, & &1.flagged),
        last_administered_at: records |> List.first() |> Map.get(:administered_at),
        records: Enum.map(records, &summarize_record/1)
      }

      {:ok, summary}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def list_flagged_events(trial_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    since = Keyword.get(opts, :since)

    with {:ok, records} <- AdministrationRecord.list_flagged(trial_id, limit: limit, since: since) do
      grouped =
        Enum.group_by(records, & &1.participant_id)
        |> Enum.map(fn {pid, recs} ->
          %{participant_id: pid, flagged_count: length(recs), events: Enum.map(recs, &summarize_record/1)}
        end)

      {:ok, %{trial_id: trial_id, total_flagged: length(records), by_participant: grouped}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def withdraw_participant(participant_id, trial_id, reason) do
    with {:ok, enrollment} <- Participant.get_enrollment(participant_id, trial_id),
         :ok <- validate_enrollment_active(enrollment) do

      {:ok, _} = Participant.update_enrollment(participant_id, trial_id, %{
        status: :withdrawn,
        withdrawn_at: DateTime.utc_now(),
        withdrawal_reason: reason
      })

      {:ok, _} = AuditLog.record(@audit_category, :withdrawn, participant_id, %{
        trial_id: trial_id,
        reason: reason
      })

      {:ok, :withdrawn}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_dose_interval(participant_id, trial_id, min_hours, administered_at) do
    case AdministrationRecord.last_for_participant(participant_id, trial_id) do
      {:ok, nil} ->
        true

      {:ok, last} ->
        hours_since = DateTime.diff(administered_at, last.administered_at, :second) / 3600
        hours_since >= min_hours

      _ ->
        true
    end
  end

  defp issue_safety_alert(record, protocol, participant) do
    alert = %SafetyAlert{
      id: generate_alert_id(),
      participant_id: record.participant_id,
      trial_id: record.trial_id,
      administration_record_id: record.id,
      alert_type: classify_alert(record, protocol),
      severity: :high,
      created_at: DateTime.utc_now()
    }

    SafetyAlert.insert(alert)
  end

  defp classify_alert(%{within_session_limit: false}, _), do: :session_limit_exceeded
  defp classify_alert(%{within_cumulative_limit: false}, _), do: :cumulative_limit_exceeded
  defp classify_alert(_, _), do: :interval_violation

  defp validate_eligibility(participant, protocol) do
    cond do
      participant.age < protocol.min_age -> {:error, :participant_too_young}
      participant.age > protocol.max_age -> {:error, :participant_too_old}
      participant.excluded -> {:error, :participant_excluded}
      true -> :ok
    end
  end

  defp validate_enrollment_active(%{status: :active}), do: :ok
  defp validate_enrollment_active(%{status: :withdrawn}), do: {:error, :participant_withdrawn}
  defp validate_enrollment_active(%{status: :completed}), do: {:error, :trial_completed}

  defp summarize_record(r) do
    %{id: r.id, dose: r.dose_amount, unit: r.dose_unit, at: r.administered_at, flagged: r.flagged}
  end

  defp generate_record_id do
    "adm_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end

  defp generate_alert_id do
    "alert_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end
end
```
