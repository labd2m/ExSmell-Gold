```elixir
# ── file: lib/compliance/audit_log.ex ────────────────────────────────────────

defmodule Compliance.AuditLog do
  @moduledoc """
  Records immutable audit trail entries for security-sensitive operations.
  Writes to an append-only table and publishes events to the SIEM pipeline.
  """

  alias Compliance.{SIEMPublisher, LogStore, RequestContext}

  @sensitive_actions [
    :user_login,
    :user_logout,
    :password_changed,
    :permission_granted,
    :permission_revoked,
    :data_exported,
    :record_deleted,
    :admin_action,
    :api_key_created,
    :api_key_revoked
  ]

  @type entry :: %{
          id: String.t(),
          action: atom(),
          actor_id: String.t() | nil,
          resource_type: String.t() | nil,
          resource_id: String.t() | nil,
          metadata: map(),
          ip_address: String.t() | nil,
          user_agent: String.t() | nil,
          occurred_at: DateTime.t(),
          severity: :info | :warning | :critical
        }

  @spec record(atom(), map(), keyword()) :: {:ok, entry()} | {:error, term()}
  def record(action, metadata, opts \\ []) when is_atom(action) do
    context = RequestContext.current()

    severity = determine_severity(action)
    actor_id = Keyword.get(opts, :actor_id) || context[:user_id]
    resource_type = Keyword.get(opts, :resource_type)
    resource_id = Keyword.get(opts, :resource_id)

    entry = %{
      id: generate_id(),
      action: action,
      actor_id: actor_id,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: sanitise(metadata),
      ip_address: context[:ip_address],
      user_agent: context[:user_agent],
      occurred_at: DateTime.utc_now(),
      severity: severity
    }

    with {:ok, _} <- LogStore.append(entry) do
      if action in @sensitive_actions do
        SIEMPublisher.publish(entry)
      end

      {:ok, entry}
    end
  end

  @spec search(map()) :: {:ok, [entry()]} | {:error, term()}
  def search(filters) do
    LogStore.query(filters)
  end

  defp determine_severity(action) when action in [:record_deleted, :permission_granted, :admin_action],
    do: :critical

  defp determine_severity(action) when action in @sensitive_actions, do: :warning
  defp determine_severity(_), do: :info

  defp sanitise(metadata) do
    Map.drop(metadata, [:password, :secret, :token, :credit_card, :ssn])
  end

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end


# ── file: lib/compliance/audit_export.ex ─────────────────────────────────────

defmodule Compliance.AuditLog do
  @moduledoc """
  Handles audit log export for regulatory review, legal holds, and
  external auditor access. Produces tamper-evident signed exports.
  """

  alias Compliance.{LogStore, ExportSigner, StorageBucket, Notifier}

  @supported_formats [:json, :csv, :ndjson]
  @max_export_days 365

  @type export_options :: %{
          from: DateTime.t(),
          to: DateTime.t(),
          format: atom(),
          actions: [atom()] | :all,
          actor_id: String.t() | nil
        }

  @spec export(export_options(), keyword()) :: {:ok, map()} | {:error, term()}
  def export(opts, meta \\ []) do
    with :ok <- validate_date_range(opts.from, opts.to),
         :ok <- validate_format(opts.format),
         {:ok, entries} <- LogStore.query(build_query(opts)) do
      content = render(entries, opts.format)
      signature = ExportSigner.sign(content)

      path = build_path(opts)
      {:ok, url} = StorageBucket.put(path, content)

      export_record = %{
        id: generate_id(),
        format: opts.format,
        entry_count: length(entries),
        period_from: opts.from,
        period_to: opts.to,
        signature: signature,
        download_url: url,
        exported_by: Keyword.get(meta, :requested_by),
        exported_at: DateTime.utc_now()
      }

      if notify = Keyword.get(meta, :notify_email) do
        Notifier.send_export_ready(notify, export_record)
      end

      {:ok, export_record}
    end
  end

  @spec verify_export(binary(), String.t()) :: :ok | {:error, :signature_invalid}
  def verify_export(content, signature) do
    if ExportSigner.verify(content, signature), do: :ok, else: {:error, :signature_invalid}
  end

  defp validate_date_range(from, to) do
    diff_days = DateTime.diff(to, from, :second) / 86_400
    cond do
      DateTime.compare(from, to) != :lt -> {:error, :invalid_date_range}
      diff_days > @max_export_days -> {:error, :range_too_large}
      true -> :ok
    end
  end

  defp validate_format(f) when f in @supported_formats, do: :ok
  defp validate_format(f), do: {:error, {:unsupported_format, f}}

  defp build_query(%{from: from, to: to, actions: :all, actor_id: nil}),
    do: %{occurred_at: {from, to}}

  defp build_query(%{from: from, to: to, actions: actions, actor_id: actor_id}) do
    q = %{occurred_at: {from, to}}
    q = if actions == :all, do: q, else: Map.put(q, :action, actions)
    if actor_id, do: Map.put(q, :actor_id, actor_id), else: q
  end

  defp render(entries, :json), do: Jason.encode!(entries)
  defp render(entries, :ndjson), do: Enum.map_join(entries, "\n", &Jason.encode!/1)
  defp render(entries, :csv), do: CSV.encode(entries)

  defp build_path(%{from: from, to: to, format: fmt}) do
    "audit-exports/#{Date.to_iso8601(from)}_#{Date.to_iso8601(to)}.#{fmt}"
  end

  defp generate_id, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
end
```
