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

  defmacro __using__(_opts) do
    quote do
      import Audit.SerializeHelpers
      alias Audit.EventStore

      @max_payload_bytes 8_192
      @redact_fields     [:password, :token, :secret, :cvv, :ssn, :pan, :api_key]
    end
  end
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
  use Audit.SerializeHelpers

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
