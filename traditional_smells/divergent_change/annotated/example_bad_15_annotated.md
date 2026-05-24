# Annotated Example — Divergent Change

| Field | Value |
|---|---|
| **Smell name** | Divergent Change |
| **Expected smell location** | `AuditTracker` module |
| **Affected functions** | `log_event/3`, `search_audit_log/1`, `purge_old_entries/1` (audit logging reason) and `generate_compliance_report/2`, `check_policy_violations/1`, `export_compliance_csv/1` (compliance reporting reason) and `trigger_alert/2`, `list_unresolved_alerts/0`, `acknowledge_alert/2` (alerting reason) |
| **Explanation** | The module conflates audit event logging, compliance reporting, and security alerting — three distinct governance concerns. Changes to log storage, to compliance framework requirements, or to alerting thresholds and channels would each independently require changes to this module. |

```elixir
defmodule Governance.AuditTracker do
  @moduledoc """
  Handles audit event logging, compliance report generation, and security alerting.
  """

  alias Governance.Repo
  alias Governance.Audit.AuditLog
  alias Governance.Compliance.PolicyViolation
  alias Governance.Alerts.Alert

  import Ecto.Query
  require Logger

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module has three distinct reasons
  # to change: (1) how and where audit events are stored, (2) which compliance
  # policies are evaluated and how reports are formatted, and (3) alerting
  # thresholds, escalation logic, and notification routing. These are governed
  # by different teams (security, compliance, and operations) and change
  # independently of one another.

  ## ── Audit Logging ────────────────────────────────────────────────────────────

  @doc "Persists an audit event for a given actor and resource."
  @spec log_event(String.t(), atom(), map()) :: {:ok, AuditLog.t()} | {:error, term()}
  def log_event(actor_id, action, context) do
    attrs = %{
      actor_id: actor_id,
      action: action,
      resource_type: context[:resource_type],
      resource_id: context[:resource_id],
      ip_address: context[:ip_address],
      user_agent: context[:user_agent],
      metadata: Map.drop(context, [:resource_type, :resource_id, :ip_address, :user_agent]),
      occurred_at: DateTime.utc_now()
    }

    case Repo.insert(AuditLog.changeset(%AuditLog{}, attrs)) do
      {:ok, log} = result ->
        Logger.debug("Audit: #{actor_id} performed #{action} on #{context[:resource_type]}")
        result

      error ->
        error
    end
  end

  @doc "Searches audit logs with optional filters."
  @spec search_audit_log(map()) :: [AuditLog.t()]
  def search_audit_log(filters) do
    base = from(a in AuditLog)

    base
    |> maybe_filter_actor(filters[:actor_id])
    |> maybe_filter_action(filters[:action])
    |> maybe_filter_date_range(filters[:from], filters[:to])
    |> maybe_filter_resource(filters[:resource_type], filters[:resource_id])
    |> order_by([a], desc: a.occurred_at)
    |> limit(^(filters[:limit] || 500))
    |> Repo.all()
  end

  @doc "Purges audit log entries older than the given number of days."
  @spec purge_old_entries(pos_integer()) :: {non_neg_integer(), nil}
  def purge_old_entries(older_than_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -older_than_days * 86_400, :second)

    AuditLog
    |> where([a], a.occurred_at < ^cutoff)
    |> Repo.delete_all()
  end

  ## ── Compliance Reporting ─────────────────────────────────────────────────────

  @doc "Generates a compliance report for a specified framework and date range."
  @spec generate_compliance_report(atom(), map()) :: map()
  def generate_compliance_report(framework, %{from: from, to: to}) do
    logs =
      AuditLog
      |> where([a], a.occurred_at >= ^from and a.occurred_at <= ^to)
      |> Repo.all()

    violations = check_policy_violations(logs)

    %{
      framework: framework,
      period: %{from: from, to: to},
      total_events: length(logs),
      unique_actors: logs |> Enum.map(& &1.actor_id) |> Enum.uniq() |> length(),
      violations: violations,
      compliant: violations == [],
      generated_at: DateTime.utc_now()
    }
  end

  @doc "Checks a list of audit logs for policy violations."
  @spec check_policy_violations([AuditLog.t()]) :: [PolicyViolation.t()]
  def check_policy_violations(logs) do
    logs
    |> Enum.filter(&policy_violation?/1)
    |> Enum.map(fn log ->
      %PolicyViolation{
        log_id: log.id,
        actor_id: log.actor_id,
        action: log.action,
        violation_type: classify_violation(log),
        detected_at: DateTime.utc_now()
      }
    end)
  end

  @doc "Exports a compliance report as a CSV binary."
  @spec export_compliance_csv(map()) :: String.t()
  def export_compliance_csv(%{violations: violations} = _report) do
    header = "log_id,actor_id,action,violation_type,detected_at"

    rows =
      Enum.map(violations, fn v ->
        "#{v.log_id},#{v.actor_id},#{v.action},#{v.violation_type},#{v.detected_at}"
      end)

    Enum.join([header | rows], "\n")
  end

  ## ── Security Alerting ────────────────────────────────────────────────────────

  @doc "Raises a security alert, persisting it and notifying the on-call team."
  @spec trigger_alert(atom(), map()) :: {:ok, Alert.t()} | {:error, term()}
  def trigger_alert(alert_type, context) do
    attrs = %{
      alert_type: alert_type,
      severity: severity_for(alert_type),
      actor_id: context[:actor_id],
      resource_id: context[:resource_id],
      description: context[:description],
      status: :unresolved,
      triggered_at: DateTime.utc_now()
    }

    case Repo.insert(Alert.changeset(%Alert{}, attrs)) do
      {:ok, alert} = result ->
        notify_security_team(alert)
        result

      error ->
        error
    end
  end

  @doc "Returns all unresolved alerts, ordered by severity and time."
  @spec list_unresolved_alerts() :: [Alert.t()]
  def list_unresolved_alerts do
    severity_rank = %{critical: 0, high: 1, medium: 2, low: 3}

    Alert
    |> where([a], a.status == :unresolved)
    |> Repo.all()
    |> Enum.sort_by(&{Map.get(severity_rank, &1.severity, 99), &1.triggered_at})
  end

  @doc "Marks an alert as acknowledged by a security analyst."
  @spec acknowledge_alert(Alert.t(), String.t()) :: {:ok, Alert.t()} | {:error, term()}
  def acknowledge_alert(%Alert{status: :unresolved} = alert, analyst_id) do
    alert
    |> Alert.changeset(%{
      status: :acknowledged,
      acknowledged_by: analyst_id,
      acknowledged_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  def acknowledge_alert(%Alert{}, _), do: {:error, :already_acknowledged}

  ## ── Private Helpers ──────────────────────────────────────────────────────────

  defp maybe_filter_actor(q, nil), do: q
  defp maybe_filter_actor(q, id), do: where(q, [a], a.actor_id == ^id)

  defp maybe_filter_action(q, nil), do: q
  defp maybe_filter_action(q, action), do: where(q, [a], a.action == ^action)

  defp maybe_filter_date_range(q, nil, nil), do: q
  defp maybe_filter_date_range(q, from, nil), do: where(q, [a], a.occurred_at >= ^from)
  defp maybe_filter_date_range(q, nil, to), do: where(q, [a], a.occurred_at <= ^to)
  defp maybe_filter_date_range(q, from, to), do: where(q, [a], a.occurred_at >= ^from and a.occurred_at <= ^to)

  defp maybe_filter_resource(q, nil, _), do: q
  defp maybe_filter_resource(q, type, nil), do: where(q, [a], a.resource_type == ^type)
  defp maybe_filter_resource(q, type, id), do: where(q, [a], a.resource_type == ^type and a.resource_id == ^id)

  defp policy_violation?(%AuditLog{action: :bulk_export}), do: true
  defp policy_violation?(%AuditLog{action: :admin_impersonate}), do: true
  defp policy_violation?(_), do: false

  defp classify_violation(%AuditLog{action: :bulk_export}), do: :data_exfiltration_risk
  defp classify_violation(%AuditLog{action: :admin_impersonate}), do: :privilege_abuse
  defp classify_violation(_), do: :unknown

  defp severity_for(:unauthorized_access), do: :critical
  defp severity_for(:bulk_export), do: :high
  defp severity_for(:failed_login_burst), do: :medium
  defp severity_for(_), do: :low

  defp notify_security_team(%Alert{severity: :critical} = alert) do
    Logger.error("CRITICAL ALERT: #{alert.alert_type} for actor #{alert.actor_id}")
    Governance.Notifications.page_oncall(alert)
  end

  defp notify_security_team(%Alert{} = alert) do
    Logger.warning("Security alert: #{alert.alert_type}")
    Governance.Notifications.notify_slack(alert)
  end

  # VALIDATION: SMELL END
end
```
