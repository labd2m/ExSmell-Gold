# Annotated Bad Example 20: Untested Polymorphic Behaviors

## Metadata

- **Smell name**: Untested Polymorphic Behaviors
- **Expected smell location**: `Audit.EventSerializer.flatten_event_fields/1`
- **Affected function(s)**: `flatten_event_fields/1`
- **Short explanation**: The function calls `Enum.into/2` on the `fields` parameter without any guard clause, relying on the `Enumerable` protocol. This protocol is not implemented for scalar types like `Integer`, `Float`, `Atom`, or `BitString`. Passing a plain binary (a common mistake when a caller passes a JSON string instead of a decoded map) will raise `Protocol.UndefinedError` at runtime instead of a clear `FunctionClauseError` at the boundary. The function's intent is to accept a `Map` or a `Keyword` list, but this is nowhere enforced.

## Code

```elixir
defmodule Audit.EventSerializer do
  @moduledoc """
  Serializes audit events to a flat key-value structure suitable for
  storage in the audit log table or forwarding to an external SIEM system.

  All field keys are normalized to snake_case strings and all values are
  converted to their string representations before storage.
  """

  @reserved_keys ~w(event_id event_type occurred_at actor_id actor_type)
  @max_fields 50

  @doc """
  Serializes a full audit event into a flat string map ready for persistence.

  ## Parameters
    - `event_type`: An atom identifying the event category.
    - `actor`: A map with `:id` and `:type` identifying who triggered the event.
    - `fields`: A map or keyword list of additional event-specific fields.
  """
  def serialize(event_type, actor, fields)
      when is_atom(event_type) and is_map(actor) do
    base = %{
      "event_id" => generate_event_id(),
      "event_type" => Atom.to_string(event_type),
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "actor_id" => Map.fetch!(actor, :id),
      "actor_type" => actor |> Map.fetch!(:type) |> Atom.to_string()
    }

    extra = flatten_event_fields(fields)

    Map.merge(base, extra)
  end

  @doc """
  Flattens an event-specific fields collection into a normalized string map.
  Reserved top-level keys are dropped to prevent overwriting core event metadata.
  """
  # VALIDATION: SMELL START - Untested Polymorphic Behaviors
  # VALIDATION: This is a smell because `Enum.into/2` depends on the `Enumerable`
  # protocol. No guard clause restricts `fields` to types that implement it. A
  # caller passing a raw JSON string (binary) instead of a decoded map will receive
  # `Protocol.UndefinedError` deep in the Enum internals instead of a clear
  # `FunctionClauseError` at this function boundary. Additionally, passing a
  # `Keyword` list where a `Map` is expected is silently accepted but produces
  # differently structured output (list of `{"key", "val"}` tuples vs a flat map),
  # which may corrupt the audit log schema.
  def flatten_event_fields(fields) do
    fields
    |> Enum.into(%{}, fn {k, v} ->
      normalized_key = to_string(k)
      {normalized_key, serialize_field_value(v)}
    end)
    |> Map.drop(@reserved_keys)
    |> Enum.take(@max_fields)
    |> Map.new()
  end
  # VALIDATION: SMELL END

  @doc """
  Converts a field value to its string representation for storage.
  """
  def serialize_field_value(nil), do: ""
  def serialize_field_value(v) when is_binary(v), do: v
  def serialize_field_value(v) when is_integer(v), do: Integer.to_string(v)
  def serialize_field_value(v) when is_float(v), do: Float.to_string(v)
  def serialize_field_value(v) when is_atom(v), do: Atom.to_string(v)
  def serialize_field_value(v) when is_boolean(v), do: to_string(v)
  def serialize_field_value(_v), do: "[complex value]"

  @doc """
  Validates that the serialized event has all required top-level keys.
  """
  def valid_serialized_event?(event) when is_map(event) do
    Enum.all?(@reserved_keys, &Map.has_key?(event, &1))
  end

  @doc """
  Produces a compact single-line summary of an event for log tailing.
  """
  def to_log_line(event) when is_map(event) do
    type = Map.get(event, "event_type", "unknown")
    actor = Map.get(event, "actor_id", "unknown")
    ts = Map.get(event, "occurred_at", "")
    "[#{ts}] #{type} by #{actor}"
  end

  @doc """
  Redacts sensitive field values from a serialized event before forwarding
  to external systems.
  """
  def redact(event, sensitive_keys) when is_map(event) and is_list(sensitive_keys) do
    Enum.reduce(sensitive_keys, event, fn key, acc ->
      if Map.has_key?(acc, key), do: Map.put(acc, key, "[REDACTED]"), else: acc
    end)
  end

  # --- Private ---

  defp generate_event_id do
    :crypto.strong_rand_bytes(12)
    |> Base.url_encode64(padding: false)
  end
end
```
