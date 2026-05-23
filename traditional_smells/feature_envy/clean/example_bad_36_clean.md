```elixir
defmodule Compliance.AuditLog do
  @moduledoc "Represents a single audit log entry."

  defstruct [
    :id,
    :actor_id,
    :actor_type,
    :action,
    :resource_type,
    :resource_id,
    :outcome,
    :metadata,
    :ip_address,
    :occurred_at,
    :sensitive
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      actor_id: "USR-303",
      actor_type: :user,
      action: :export_records,
      resource_type: :customer_data,
      resource_id: "DS-4411",
      outcome: :success,
      metadata: %{record_count: 1500, format: "csv"},
      ip_address: "203.0.113.42",
      occurred_at: ~U[2024-03-14 14:00:00Z],
      sensitive: true
    }
  end

  def actor_label(%__MODULE__{actor_id: id, actor_type: :user}),    do: "user:#{id}"
  def actor_label(%__MODULE__{actor_id: id, actor_type: :service}), do: "service:#{id}"
  def actor_label(%__MODULE__{actor_id: id}),                       do: "unknown:#{id}"

  def action_category(%__MODULE__{action: action}) do
    cond do
      action in [:read, :list, :export_records] -> :data_access
      action in [:create, :update, :delete]     -> :data_mutation
      action in [:login, :logout, :mfa_verify]  -> :authentication
      true                                      -> :other
    end
  end

  def is_sensitive?(%__MODULE__{sensitive: true}), do: true
  def is_sensitive?(_), do: false

  def outcome_label(%__MODULE__{outcome: :success}),  do: "SUCCESS"
  def outcome_label(%__MODULE__{outcome: :failure}),  do: "FAILURE"
  def outcome_label(%__MODULE__{outcome: :denied}),   do: "DENIED"
  def outcome_label(_),                               do: "UNKNOWN"

  def occurred_on(%__MODULE__{occurred_at: ts}) do
    DateTime.to_date(ts)
  end
end

defmodule Compliance.AuditReport do
  @moduledoc """
  Generates structured compliance audit reports for export to
  external regulators or internal security dashboards.
  """

  alias Compliance.AuditLog
  require Logger

  @doc """
  Builds a compliance report for the given list of audit log entry IDs.
  """
  def build(log_ids, report_label) do
    entries = Enum.map(log_ids, &format_audit_entry/1)

    sensitive_count = Enum.count(entries, & &1.sensitive)

    %{
      label:           report_label,
      entries:         entries,
      total:           length(entries),
      sensitive_count: sensitive_count,
      generated_at:    DateTime.utc_now()
    }
  end

  @doc "Exports a report map to newline-delimited JSON for archival."
  def export_ndjson(%{entries: entries}) do
    entries
    |> Enum.map(&Jason.encode!/1)
    |> Enum.join("\n")
  end

  defp format_audit_entry(log_id) do
    entry    = AuditLog.get!(log_id)
    actor    = AuditLog.actor_label(entry)
    category = AuditLog.action_category(entry)
    sensitive = AuditLog.is_sensitive?(entry)
    outcome  = AuditLog.outcome_label(entry)

    %{
      id:            entry.id,
      actor:         actor,
      action:        entry.action,
      category:      category,
      resource_type: entry.resource_type,
      resource_id:   entry.resource_id,
      outcome:       outcome,
      sensitive:     sensitive,
      ip:            entry.ip_address,
      occurred_at:   entry.occurred_at
    }
  end
end
```
