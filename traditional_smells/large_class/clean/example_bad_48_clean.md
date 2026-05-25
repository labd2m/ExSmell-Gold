```elixir
defmodule AuditCompliance do
  @moduledoc """
  Centralised compliance hub: audit event recording, anomaly management,
  data retention, audit-trail export, compliance reports, GDPR consent,
  log archival, and compliance alert delivery.
  """

  require Logger
  import Ecto.Query
  alias Compliance.Repo
  alias Compliance.AuditEvent
  alias Compliance.Anomaly
  alias Compliance.GdprConsent
  alias Compliance.ArchivedLog

  @retention_days 365
  @archive_batch_size 500
  @alert_recipients Application.compile_env(:compliance, :alert_recipients, ["compliance@example.com"])


  def record_event(actor_id, action, context \\ %{}) do
    attrs = %{
      actor_id: actor_id,
      action: action,
      context: context,
      ip_address: Map.get(context, :ip_address),
      occurred_at: DateTime.utc_now()
    }

    case Repo.insert(AuditEvent.changeset(%AuditEvent{}, attrs)) do
      {:ok, event} ->
        maybe_flag_anomaly(event)
        {:ok, event}

      {:error, cs} ->
        Logger.error("Failed to record audit event: #{inspect(cs.errors)}")
        {:error, cs}
    end
  end

  defp maybe_flag_anomaly(%AuditEvent{action: action} = event) do
    suspicious_actions = [:bulk_delete, :export_all, :privilege_escalation, :failed_login]

    if action in suspicious_actions do
      flag_anomaly(event, "Suspicious action detected: #{action}")
    end
  end


  def flag_anomaly(%AuditEvent{} = event, reason) do
    attrs = %{
      audit_event_id: event.id,
      actor_id: event.actor_id,
      reason: reason,
      severity: classify_severity(event.action),
      status: :open,
      flagged_at: DateTime.utc_now()
    }

    case Repo.insert(Anomaly.changeset(%Anomaly{}, attrs)) do
      {:ok, anomaly} ->
        Logger.warning("Anomaly #{anomaly.id} flagged for event #{event.id}: #{reason}")
        send_compliance_alert(anomaly, :anomaly_detected)
        {:ok, anomaly}

      {:error, cs} ->
        {:error, cs}
    end
  end

  defp classify_severity(:bulk_delete), do: :critical
  defp classify_severity(:privilege_escalation), do: :high
  defp classify_severity(:export_all), do: :medium
  defp classify_severity(_), do: :low

  def resolve_anomaly(%Anomaly{} = anomaly, resolver_id) do
    anomaly
    |> Anomaly.changeset(%{
         status: :resolved,
         resolved_by: resolver_id,
         resolved_at: DateTime.utc_now()
       })
    |> Repo.update()
  end


  def run_data_retention_policy do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_days * 86_400, :second)

    {deleted, _} =
      from(e in AuditEvent, where: e.occurred_at < ^cutoff)
      |> Repo.delete_all()

    Logger.info("Data retention: deleted #{deleted} audit events older than #{@retention_days} days")
    {:ok, deleted}
  end


  def generate_audit_trail(actor_id, opts \\ []) do
    from_dt = Keyword.get(opts, :from)
    to_dt   = Keyword.get(opts, :to)
    limit   = Keyword.get(opts, :limit, 100)

    query =
      from(e in AuditEvent,
        where: e.actor_id == ^actor_id,
        order_by: [desc: e.occurred_at],
        limit: ^limit
      )

    query = if from_dt, do: where(query, [e], e.occurred_at >= ^from_dt), else: query
    query = if to_dt,   do: where(query, [e], e.occurred_at <= ^to_dt),   else: query

    Repo.all(query)
  end


  def export_compliance_report(from_date, to_date) do
    events = generate_audit_trail(nil, from: from_date, to: to_date, limit: 10_000)

    anomalies =
      from(a in Anomaly,
        where: a.flagged_at >= ^from_date and a.flagged_at <= ^to_date,
        order_by: [desc: a.flagged_at]
      )
      |> Repo.all()

    %{
      period: %{from: from_date, to: to_date},
      total_events: length(events),
      total_anomalies: length(anomalies),
      critical_anomalies: Enum.count(anomalies, &(&1.severity == :critical)),
      open_anomalies: Enum.count(anomalies, &(&1.status == :open)),
      events: events,
      anomalies: anomalies,
      generated_at: DateTime.utc_now()
    }
  end


  def verify_gdpr_consent(user_id) do
    case Repo.get_by(GdprConsent, user_id: user_id, revoked: false) do
      nil    -> {:error, :no_consent}
      consent -> {:ok, consent}
    end
  end

  def revoke_gdpr_consent(user_id) do
    case Repo.get_by(GdprConsent, user_id: user_id, revoked: false) do
      nil ->
        {:error, :not_found}

      consent ->
        consent
        |> GdprConsent.changeset(%{revoked: true, revoked_at: DateTime.utc_now()})
        |> Repo.update()
    end
  end


  def archive_old_logs(before_date) do
    query =
      from(e in AuditEvent,
        where: e.occurred_at < ^before_date,
        limit: @archive_batch_size
      )

    events = Repo.all(query)

    Enum.each(events, fn event ->
      Repo.insert!(
        ArchivedLog.changeset(%ArchivedLog{}, %{
          original_id: event.id,
          data: Map.from_struct(event),
          archived_at: DateTime.utc_now()
        })
      )

      Repo.delete!(event)
    end)

    Logger.info("Archived #{length(events)} audit logs before #{before_date}")
    {:ok, length(events)}
  end


  def send_compliance_alert(%Anomaly{} = anomaly, alert_type) do
    body = """
    Compliance alert:

    Anomaly ID:
    Actor:
    Reason:
    Severity:
    Flagged at:
    """

    Enum.each(@alert_recipients, fn email ->
      Mailer.deliver(%{
        to: email,
        subject: "[COMPLIANCE] #{alert_type} — Severity: #{anomaly.severity}",
        text_body: body
      })
    end)

    :ok
  end
end
```
