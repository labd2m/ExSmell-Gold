# Code Smell Annotation

- **Smell name:** Working with invalid data
- **Expected smell location:** `AuditLogger.log_event/4`, where `metadata` is passed directly to `Jason.encode!/1`
- **Affected function(s):** `log_event/4`
- **Short explanation:** The `metadata` parameter is passed without validation to `Jason.encode!/1`, which requires a JSON-serializable term. If a caller passes a struct that has no `Jason.Encoder` implementation, a `Protocol.UndefinedError` is raised deep inside the Jason library, making it appear the audit logger itself is broken rather than pointing to the invalid data passed by the caller.

```elixir
defmodule MyApp.Audit.AuditLogger do
  @moduledoc """
  Records security-sensitive and compliance-critical events to the audit trail.
  Supports structured metadata, actor attribution, and tamper-evident chaining.
  """

  require Logger

  alias MyApp.Audit.{AuditRecord, AuditChain, AuditExporter}
  alias MyApp.Repo

  @supported_event_types ~w(
    user.login user.logout user.password_changed user.mfa_enabled
    resource.created resource.updated resource.deleted resource.exported
    permission.granted permission.revoked role.assigned role.removed
    payment.initiated payment.completed payment.refunded
    api_key.created api_key.revoked
  )

  @high_severity_events ~w(
    user.password_changed permission.granted permission.revoked
    api_key.created api_key.revoked
  )

  @type actor :: %{id: String.t(), type: :user | :service | :system, ip: String.t() | nil}

  @spec log_event(actor(), String.t(), String.t(), term(), keyword()) ::
          {:ok, AuditRecord.t()} | {:error, atom()}
  def log_event(actor, event_type, resource_id, metadata, opts \\ []) do
    correlation_id = Keyword.get(opts, :correlation_id, generate_correlation_id())
    severity = determine_severity(event_type)

    with :ok <- validate_event_type(event_type) do
      # VALIDATION: SMELL START - Working with invalid data
      # VALIDATION: This is a smell because `metadata` is passed directly to
      # VALIDATION: `Jason.encode!/1` without checking that it is a
      # VALIDATION: JSON-serializable term (map, list, string, number, boolean, nil).
      # VALIDATION: If a caller passes a struct without a Jason.Encoder implementation,
      # VALIDATION: a Protocol.UndefinedError will be raised inside Jason, with no
      # VALIDATION: message identifying the bad input at the log_event/4 boundary.
      encoded_metadata = Jason.encode!(metadata)
      # VALIDATION: SMELL END

      previous_hash = AuditChain.latest_hash()

      record_attrs = %{
        id: Ecto.UUID.generate(),
        actor_id: actor.id,
        actor_type: to_string(actor.type),
        actor_ip: actor.ip,
        event_type: event_type,
        resource_id: resource_id,
        metadata_json: encoded_metadata,
        severity: severity,
        correlation_id: correlation_id,
        chain_hash: compute_chain_hash(previous_hash, event_type, actor.id, resource_id),
        occurred_at: DateTime.utc_now()
      }

      case AuditRecord.insert(record_attrs) do
        {:ok, record} ->
          AuditChain.update_hash(record.chain_hash)
          maybe_alert_on_severity(record)
          {:ok, record}

        {:error, changeset} ->
          Logger.error("Audit log insert failed: #{inspect(changeset.errors)}")
          {:error, :persistence_failed}
      end
    end
  end

  @spec search(map(), keyword()) :: {:ok, [AuditRecord.t()], integer()} | {:error, atom()}
  def search(filters, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)

    with {:ok, records, total} <- AuditRecord.search(filters, page, per_page) do
      {:ok, records, total}
    end
  end

  @spec export(String.t(), Date.t(), Date.t(), atom()) ::
          {:ok, String.t()} | {:error, atom()}
  def export(requester_id, date_from, date_to, format \\ :csv) do
    with {:ok, records} <- AuditRecord.fetch_range(date_from, date_to) do
      log_event(
        %{id: "system", type: :system, ip: nil},
        "resource.exported",
        requester_id,
        %{date_from: Date.to_string(date_from), date_to: Date.to_string(date_to), format: format}
      )

      AuditExporter.export(records, format)
    end
  end

  # Private helpers

  defp validate_event_type(type) when type in @supported_event_types, do: :ok
  defp validate_event_type(type) do
    Logger.warning("Unknown audit event type: #{type}")
    {:error, :unknown_event_type}
  end

  defp determine_severity(event_type) when event_type in @high_severity_events, do: :high
  defp determine_severity(_), do: :normal

  defp compute_chain_hash(prev_hash, event_type, actor_id, resource_id) do
    content = "#{prev_hash}|#{event_type}|#{actor_id}|#{resource_id}"
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp maybe_alert_on_severity(%{severity: :high} = record) do
    Logger.warning("High severity audit event: #{record.event_type} by #{record.actor_id}")
  end

  defp maybe_alert_on_severity(_record), do: :ok

  defp generate_correlation_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
```
