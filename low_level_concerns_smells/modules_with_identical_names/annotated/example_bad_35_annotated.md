# Annotated Example 35 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with identical names
- **Expected smell location:** Both `defmodule Audit.Logger` declarations
- **Affected functions:** `Audit.Logger.log/3`, `Audit.Logger.log_access/3`, `Audit.Logger.log_change/4`, `Audit.Logger.query/1`, `Audit.Logger.export/2`
- **Short explanation:** Two separate source files both declare `defmodule Audit.Logger`. BEAM silently drops one definition at load time. In an audit logging context this is especially dangerous: if the module providing `log/3` or `log_change/4` is discarded, audit records stop being created without any visible error in the application flow.

---

```elixir
# ── file: lib/audit/logger.ex ───────────────────────────────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This is a smell because `Audit.Logger` is declared here and also
# in a second block below. BEAM retains only one definition, silently dropping
# audit log functions that are critical for compliance and traceability.

defmodule Audit.Logger do
  @moduledoc """
  Immutable audit trail writer for compliance and security events.
  Defined in `lib/audit/logger.ex`.
  """

  alias Audit.{AuditStore, Serialiser, RetentionPolicy}

  @event_categories [:access, :change, :auth, :admin, :billing]
  @severity_levels [:info, :warning, :critical]

  @type actor :: %{id: String.t(), type: :user | :service | :system}
  @type resource :: %{type: String.t(), id: String.t()}

  @type audit_entry :: %{
    id: String.t(),
    actor: actor(),
    action: String.t(),
    resource: resource(),
    category: atom(),
    severity: atom(),
    metadata: map(),
    ip_address: String.t() | nil,
    occurred_at: DateTime.t()
  }

  @doc """
  Log an arbitrary auditable event.
  `actor` is the entity performing the action; `action` is a dot-namespaced
  event name like `"billing.invoice.voided"`.
  """
  @spec log(actor(), String.t(), map()) :: {:ok, audit_entry()} | {:error, String.t()}
  def log(actor, action, opts \\ %{}) do
    category = infer_category(action)
    severity = Map.get(opts, :severity, :info)

    unless severity in @severity_levels do
      {:error, "Unknown severity: #{severity}"}
    else
      entry = %{
        id: generate_id(),
        actor: actor,
        action: action,
        resource: Map.get(opts, :resource, %{}),
        category: category,
        severity: severity,
        metadata: Map.get(opts, :metadata, %{}),
        ip_address: Map.get(opts, :ip_address),
        occurred_at: DateTime.utc_now()
      }

      with {:ok, serialised} <- Serialiser.encode(entry),
           :ok <- AuditStore.append(serialised) do
        {:ok, entry}
      end
    end
  end

  @doc "Record a resource access event (read, list, download, etc.)."
  @spec log_access(actor(), resource(), String.t()) :: {:ok, audit_entry()} | {:error, String.t()}
  def log_access(actor, resource, action_verb) do
    log(actor, "#{resource.type}.#{action_verb}", %{
      category: :access,
      resource: resource
    })
  end

  @doc "Record a mutation event with before/after snapshots."
  @spec log_change(actor(), resource(), map(), map()) ::
          {:ok, audit_entry()} | {:error, String.t()}
  def log_change(actor, resource, before_snapshot, after_snapshot) do
    diff = compute_diff(before_snapshot, after_snapshot)

    log(actor, "#{resource.type}.updated", %{
      category: :change,
      resource: resource,
      severity: :info,
      metadata: %{diff: diff}
    })
  end

  @doc "Query the audit log with filters."
  @spec query(keyword()) :: {:ok, [audit_entry()]} | {:error, String.t()}
  def query(filters) do
    valid_keys = [:actor_id, :action, :category, :from, :to, :severity, :resource_type]
    unknown = Keyword.keys(filters) -- valid_keys

    if unknown != [] do
      {:error, "Unknown filter keys: #{inspect(unknown)}"}
    else
      AuditStore.query(filters)
    end
  end

  @doc "Export audit entries in a given time range to a structured format."
  @spec export(keyword(), :json | :csv) :: {:ok, binary()} | {:error, String.t()}
  def export(filters, format) when format in [:json, :csv] do
    with {:ok, entries} <- query(filters) do
      Serialiser.export(entries, format)
    end
  end

  def export(_filters, format), do: {:error, "Unsupported export format: #{format}"}

  defp infer_category(action) do
    prefix = action |> String.split(".") |> List.first() |> String.to_atom()
    if prefix in @event_categories, do: prefix, else: :access
  end

  defp compute_diff(before, after_snap) do
    all_keys = Map.keys(before) ++ Map.keys(after_snap) |> Enum.uniq()

    Enum.reduce(all_keys, %{}, fn key, acc ->
      bv = Map.get(before, key)
      av = Map.get(after_snap, key)
      if bv != av, do: Map.put(acc, key, %{before: bv, after: av}), else: acc
    end)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end
end

# VALIDATION: SMELL END

# ── file: lib/audit/logger_retention.ex  (retention sweep added in a new file;
#    developer accidentally reused the parent module name) ────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This second `defmodule Audit.Logger` replaces the first in BEAM.
# `log/3`, `log_access/3`, `log_change/4`, `query/1`, and `export/2` all
# become permanently unavailable, silently disabling the audit trail.

defmodule Audit.Logger do
  @moduledoc """
  Retention policy enforcement for audit log records.
  Was intended to be `Audit.Logger.Retention` but was accidentally given the
  same module name as the core audit logger.
  """

  alias Audit.{AuditStore, RetentionPolicy, ArchiveBackend}

  @doc "Purge audit entries older than the configured retention period."
  @spec purge_expired() :: {:ok, non_neg_integer()} | {:error, String.t()}
  def purge_expired do
    cutoff = RetentionPolicy.cutoff_datetime()
    AuditStore.delete_before(cutoff)
  end

  @doc "Archive entries that are past the hot-storage window but within retention."
  @spec archive_cold() :: {:ok, non_neg_integer()} | {:error, String.t()}
  def archive_cold do
    hot_cutoff = DateTime.add(DateTime.utc_now(), -RetentionPolicy.hot_days() * 86_400, :second)
    cold_cutoff = RetentionPolicy.cutoff_datetime()

    entries = AuditStore.query(from: cold_cutoff, to: hot_cutoff)

    case ArchiveBackend.store(entries) do
      {:ok, _} ->
        AuditStore.delete_range(cold_cutoff, hot_cutoff)
        {:ok, length(entries)}

      {:error, reason} ->
        {:error, "Archive failed: #{inspect(reason)}"}
    end
  end

  @doc "Return the current retention policy settings."
  @spec current_policy() :: map()
  def current_policy do
    %{
      hot_days: RetentionPolicy.hot_days(),
      total_days: RetentionPolicy.total_days(),
      archive_enabled: RetentionPolicy.archive_enabled?()
    }
  end
end

# VALIDATION: SMELL END
```
