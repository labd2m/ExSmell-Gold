# example_bad_15_clean

```elixir
defmodule Scheduling.CalendarSyncHandler do
  @moduledoc """
  Synchronises internal scheduling events with an external calendar provider,
  applying provider responses to maintain consistent event state.
  """

  alias Scheduling.CalendarProviderClient
  alias Scheduling.CalendarStore
  alias Scheduling.ConflictQueue
  alias Scheduling.RecurringRuleValidator
  alias Scheduling.AttendeeNotifier
  alias Scheduling.AuditLogger

  @max_attendees 200
  @past_event_grace_minutes 15

  def sync_event(event_id, calendar_id, operator_id) do
    with {:ok, event} <- CalendarStore.fetch(event_id),
         {:ok, provider_payload} <- build_provider_payload(event),
         {:ok, result} <- apply_calendar_response(event, provider_payload, operator_id),
         :ok <- CalendarStore.record_sync(event_id, result) do
      {:ok, result}
    end
  end

  defp apply_calendar_response(event, provider_payload, operator_id) do
    case CalendarProviderClient.upsert_event(event.provider_calendar_id, provider_payload) do
      {:ok, %{status: "created", provider_event_id: pid, created_at: ts}} ->
        CalendarStore.update_provider_ref(event.id, pid)
        AuditLogger.log(:calendar_event_created, operator_id, %{event_id: event.id, pid: pid})
        {:ok, %{status: :created, provider_event_id: pid, created_at: ts}}

      {:ok, %{status: "updated", provider_event_id: pid, version: ver, updated_at: ts}} ->
        CalendarStore.update_version(event.id, ver)
        AuditLogger.log(:calendar_event_updated, operator_id, %{event_id: event.id, version: ver})
        {:ok, %{status: :updated, provider_event_id: pid, version: ver, updated_at: ts}}

      {:ok, %{status: "conflict", conflicting_event_id: cid, conflict_type: ctype}} ->
        ConflictQueue.enqueue(event.id, cid, ctype, operator_id)
        AuditLogger.log(:calendar_conflict, operator_id, %{event_id: event.id, conflicting: cid})
        {:error, {:conflict, %{conflicting_event_id: cid, type: ctype}}}

      {:ok, %{status: "failed", reason: "attendee_limit_exceeded", limit: lim, requested: req}} ->
        excess = req - lim
        AttendeeNotifier.notify_capacity_exceeded(event.organiser_id, lim, excess)
        {:error, {:attendee_limit_exceeded, %{limit: lim, excess: excess}}}

      {:ok, %{status: "failed", reason: "organiser_not_found", organiser_email: email}} ->
        AuditLogger.log(:organiser_not_found, operator_id, %{event_id: event.id, email: email})
        {:error, {:organiser_not_found, email}}

      {:ok, %{status: "failed", reason: "resource_unavailable", resource_id: rid}} ->
        AuditLogger.log(:resource_unavailable, operator_id, %{event_id: event.id, resource_id: rid})
        {:error, {:resource_unavailable, rid}}

      {:ok, %{status: "failed", reason: "invalid_recurrence_rule", rule: rule, detail: detail}} ->
        RecurringRuleValidator.flag_invalid(event.id, rule, detail)
        {:error, {:invalid_recurrence_rule, %{rule: rule, detail: detail}}}

      {:ok, %{status: "failed", reason: "event_in_past", start_time: st}} ->
        grace_cutoff = DateTime.add(DateTime.utc_now(), -@past_event_grace_minutes * 60, :second)
        if DateTime.compare(st, grace_cutoff) == :gt do
          {:error, {:event_in_past, st}}
        else
          AuditLogger.log(:past_event_rejected, operator_id, %{event_id: event.id, start: st})
          {:error, {:event_too_far_in_past, st}}
        end

      {:ok, %{status: "failed", reason: other}} ->
        AuditLogger.log(:calendar_unknown_failure, operator_id, %{event_id: event.id, reason: other})
        {:error, {:calendar_provider_error, other}}

      {:error, %{reason: :timeout}} ->
        {:error, :calendar_provider_timeout}

      {:error, reason} ->
        AuditLogger.log(:calendar_provider_error, operator_id, %{event_id: event.id, reason: reason})
        {:error, :calendar_provider_error}
    end
  end

  defp build_provider_payload(event) do
    {:ok,
     %{
       title: event.title,
       start_time: event.start_time,
       end_time: event.end_time,
       attendees: Enum.map(event.attendees, & &1.email),
       recurrence: event.recurrence_rule,
       location: event.location
     }}
  end
end
```
