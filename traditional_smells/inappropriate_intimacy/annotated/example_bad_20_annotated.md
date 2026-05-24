# Code Smell Example – Annotated

## Metadata

- **Smell name:** Inappropriate Intimacy
- **Expected smell location:** `AuditLogger.record/3` function
- **Affected function(s):** `AuditLogger.record/3`
- **Short explanation:** `AuditLogger.record/3` fetches an `Actor` struct and a `Resource` struct and then directly reads their internal fields (`.audit_role`, `.department_id`, `.ip_address`, `.classification_level`, `.owner_org_id`, `.pii_fields`) to build the audit entry. Extracting these audit-relevant attributes should be delegated to dedicated functions on `Actor` and `Resource`, not done by accessing raw fields inside this module.

---

```elixir
defmodule MyApp.Compliance.AuditLogger do
  @moduledoc """
  Records structured audit events for compliance and security review.
  Enriches events with actor context and resource classification metadata.
  """

  alias MyApp.Identity.Actor
  alias MyApp.Resources.Resource
  alias MyApp.Compliance.{AuditEntry, SiemExporter}

  @sensitive_actions [:delete, :export, :bulk_update, :permission_change]
  @high_risk_classifications [:secret, :top_secret]

  def record(actor_id, action, resource_ref) do
    with {:ok, actor}    <- Actor.fetch(actor_id),
         {:ok, resource} <- Resource.fetch(resource_ref) do

      # VALIDATION: SMELL START - Inappropriate Intimacy
      # VALIDATION: This is a smell because record/3 directly reads .audit_role,
      # .department_id, and .ip_address from the Actor struct, and .classification_level,
      # .owner_org_id, and .pii_fields from the Resource struct. The AuditLogger module
      # should not know about the internal field layout of Actor and Resource; instead,
      # those modules should expose dedicated functions (e.g., Actor.audit_context/1,
      # Resource.classification_metadata/1) to provide this data.
      audit_role      = actor.audit_role
      department_id   = actor.department_id
      ip_address      = actor.ip_address

      classification  = resource.classification_level
      owner_org_id    = resource.owner_org_id
      pii_fields      = resource.pii_fields
      # VALIDATION: SMELL END

      sensitive        = action in @sensitive_actions
      high_risk        = classification in @high_risk_classifications
      involves_pii     = pii_fields != []

      severity =
        cond do
          high_risk and sensitive -> :critical
          high_risk or sensitive  -> :high
          involves_pii            -> :medium
          true                    -> :low
        end

      entry = %AuditEntry{
        id:             generate_id(),
        actor_id:       actor_id,
        audit_role:     audit_role,
        department_id:  department_id,
        ip_address:     ip_address,
        action:         action,
        resource_ref:   resource_ref,
        classification: classification,
        owner_org_id:   owner_org_id,
        pii_touched:    pii_fields,
        involves_pii:   involves_pii,
        severity:       severity,
        occurred_at:    DateTime.utc_now()
      }

      persist(entry)

      if severity in [:critical, :high] do
        SiemExporter.push(entry)
      end

      {:ok, entry}
    end
  end

  def query(opts \\ []) do
    actor_id     = Keyword.get(opts, :actor_id)
    severity     = Keyword.get(opts, :severity)
    action       = Keyword.get(opts, :action)
    from         = Keyword.get(opts, :from)
    to           = Keyword.get(opts, :to)

    :ets.tab2list(:audit_entries)
    |> Enum.map(fn {_, e} -> e end)
    |> Enum.filter(fn e ->
      (is_nil(actor_id)  or e.actor_id == actor_id) and
      (is_nil(severity)  or e.severity == severity) and
      (is_nil(action)    or e.action == action) and
      (is_nil(from)      or DateTime.compare(e.occurred_at, from) != :lt) and
      (is_nil(to)        or DateTime.compare(e.occurred_at, to) != :gt)
    end)
    |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
  end

  def export_range(from, to, format \\ :jsonl) do
    entries = query(from: from, to: to)
    SiemExporter.export_batch(entries, format)
  end

  def delete_before(cutoff_date) do
    :ets.tab2list(:audit_entries)
    |> Enum.each(fn {id, entry} ->
      if DateTime.compare(entry.occurred_at, cutoff_date) == :lt do
        :ets.delete(:audit_entries, id)
      end
    end)
  end

  # --- Private helpers ---

  defp persist(entry) do
    :ets.insert(:audit_entries, {entry.id, entry})
    {:ok, entry}
  end

  defp generate_id do
    "AUD-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16())
  end
end
```
