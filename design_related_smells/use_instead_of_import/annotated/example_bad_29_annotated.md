# Annotated Bad Example 29

**Smell:** "Use" instead of "import"
**Expected Smell Location:** `Audit.ComplianceLogger`, `use Audit.SerializeHelpers` directive
**Affected Functions:** `log_action/3`, `log_data_access/3`, `flush_batch/1`, `render_entry/1`
**Explanation:** `Audit.ComplianceLogger` uses `use Audit.SerializeHelpers` to access JSON serialisation and payload-redaction utilities. The `__using__/1` macro in `SerializeHelpers` silently injects an alias for `Audit.EventStore` and sets `@max_payload_bytes` and `@redact_fields` module attributes. A reader of `ComplianceLogger` cannot determine where `EventStore`, `@max_payload_bytes`, or `@redact_fields` originate without inspecting the library macro. A simple `import Audit.SerializeHelpers` would suffice and would make dependencies visible.

```elixir
defmodule Audit.SerializeHelpers do
  @moduledoc """
  Stateless serialisation, redaction, and size-limiting helpers for audit log entries.
  """

  @default_redact_fields [:password, :token, :secret, :cvv, :ssn, :pan]

  def redact(map, fields \\ @default_redact_fields) when is_map(map) do
    Enum.reduce(fields, map, fn field, acc ->
      if Map.has_key?(acc, field) do
        Map.put(acc, field, "[REDACTED]")
      else
        acc
      end
    end)
  end

  def serialize(payload) when is_map(payload) do
    payload
    |> Jason.encode!()
  rescue
    _ -> inspect(payload)
  end

  def truncate_payload(json, max_bytes) when is_binary(json) and is_integer(max_bytes) do
    if byte_size(json) > max_bytes do
      String.slice(json, 0, max_bytes) <> "...[TRUNCATED]"
    else
      json
    end
  end

  def classify_severity(:delete),        do: :high
  def classify_severity(:update),        do: :medium
  def classify_severity(:create),        do: :low
  def classify_severity(:read),          do: :info
  def classify_severity(_),              do: :info

  def build_entry(actor_id, action, resource, payload) do
    %{
      id:         generate_entry_id(),
      actor_id:   actor_id,
      action:     action,
      resource:   resource,
      payload:    payload,
      severity:   classify_severity(action),
      timestamp:  DateTime.utc_now()
    }
  end

  defp generate_entry_id do
    "AUD-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because __using__/1 propagates alias Audit.EventStore
  # and two module attributes (@max_payload_bytes and @redact_fields) into every
  # caller. These are invisible dependencies that a reader of ComplianceLogger
  # cannot discover without reading the library macro.
  defmacro __using__(_opts) do
    quote do
      import Audit.SerializeHelpers
      alias Audit.EventStore

      @max_payload_bytes 8_192
      @redact_fields     [:password, :token, :secret, :cvv, :ssn, :pan, :api_key]
    end
  end
  # VALIDATION: SMELL END - "Use" instead of "import"
end

defmodule Audit.EventStore do
  @moduledoc "Persists audit log entries to the backing store (stub)."

  def insert(entry) do
    IO.puts("[AuditStore] #{entry.id} | #{entry.severity} | #{entry.action} on #{entry.resource}")
    {:ok, entry}
  end

  def insert_batch(entries) when is_list(entries) do
    Enum.each(entries, &insert/1)
    {:ok, length(entries)}
  end
end

defmodule Audit.ComplianceLogger do
  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because `use Audit.SerializeHelpers` silently injects
  # alias Audit.EventStore, @max_payload_bytes, and @redact_fields via __using__/1.
  # None of these appear as explicit declarations in ComplianceLogger. A reader must
  # trace through the library macro to understand the module's true dependencies.
  # `import Audit.SerializeHelpers` would be sufficient and transparent.
  use Audit.SerializeHelpers
  # VALIDATION: SMELL END - "Use" instead of "import"

  @moduledoc """
  Records compliance-grade audit log entries for regulated user actions and
  data-access events, with automatic payload redaction and size capping.
  """

  def log_action(actor_id, action, %{resource: resource} = context) do
    payload =
      context
      |> Map.drop([:resource])
      |> redact(@redact_fields)

    json = payload |> serialize() |> truncate_payload(@max_payload_bytes)

    entry = build_entry(actor_id, action, resource, json)
    EventStore.insert(entry)
  end

  def log_data_access(actor_id, resource, accessed_fields) when is_list(accessed_fields) do
    payload = %{accessed_fields: accessed_fields, count: length(accessed_fields)}
    json    = payload |> serialize() |> truncate_payload(@max_payload_bytes)

    entry = build_entry(actor_id, :read, resource, json)
    EventStore.insert(entry)
  end

  def flush_batch(entries) when is_list(entries) do
    prepared =
      Enum.map(entries, fn {actor_id, action, resource, payload} ->
        redacted = redact(payload, @redact_fields)
        json     = redacted |> serialize() |> truncate_payload(@max_payload_bytes)
        build_entry(actor_id, action, resource, json)
      end)

    EventStore.insert_batch(prepared)
  end

  def render_entry(%{id: id, actor_id: a, action: act, resource: r, severity: s, timestamp: ts}) do
    "[#{ts}] #{s |> to_string() |> String.upcase()} | #{id} | actor=#{a} action=#{act} resource=#{r}"
  end

  def high_severity?(entry), do: classify_severity(entry.action) == :high
end
```
