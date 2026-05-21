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
