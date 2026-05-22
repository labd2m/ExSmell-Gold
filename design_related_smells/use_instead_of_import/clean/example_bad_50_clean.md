```elixir
defmodule JsonSerializer do
  def encode!(term) do
    term
    |> sanitize()
    |> :json.encode()
    |> IO.iodata_to_binary()
  rescue
    _ -> "{}"
  end

  def decode!(json) when is_binary(json) do
    :json.decode(json)
  rescue
    _ -> %{}
  end

  def sanitize(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_atom(k), do: to_string(k), else: k
      {key, sanitize(v)}
    end)
  end
  def sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)
  def sanitize(val) when is_pid(val),    do: inspect(val)
  def sanitize(val) when is_reference(val), do: inspect(val)
  def sanitize(val), do: val
end

defmodule EventHelpers do
  defmacro __using__(_opts) do
    quote do
      import JsonSerializer

      @severity_levels [:debug, :info, :warning, :error, :critical]

      def valid_severity?(level), do: level in @severity_levels

      def enrich_context(context, actor) do
        Map.merge(context, %{
          actor_id:   actor.id,
          actor_role: actor.role,
          recorded_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })
      end

      def mask_sensitive(map, fields) do
        Enum.reduce(fields, map, fn field, acc ->
          if Map.has_key?(acc, field),
            do: Map.put(acc, field, "***REDACTED***"),
            else: acc
        end)
      end
    end
  end
end

defmodule AuditLogger do
  use EventHelpers

  @sensitive_fields  [:password, :token, :secret, :card_number, :cvv]
  @retention_days    365
  @batch_flush_limit 100

  def log_event(event_type, actor, context \\ %{}) do
    severity = infer_severity(event_type)

    unless valid_severity?(severity) do
      raise ArgumentError, "Unknown severity: #{severity}"
    end

    entry = build_entry(event_type, severity, actor, context)
    emit(entry)
  end

  def serialize_context(context) do
    context
    |> mask_sensitive(@sensitive_fields)
    |> sanitize()
    |> encode!()
  end

  def build_entry(event_type, severity, actor, context) do
    enriched = enrich_context(context, actor)
    cleaned  = mask_sensitive(enriched, @sensitive_fields)

    %{
      id:           "evt_#{:erlang.unique_integer([:positive])}",
      event_type:   event_type,
      severity:     severity,
      actor_id:     actor.id,
      actor_role:   actor.role,
      context_raw:  cleaned,
      context_json: encode!(cleaned),
      occurred_at:  DateTime.utc_now(),
      expires_at:   DateTime.add(DateTime.utc_now(), @retention_days * 86_400, :second)
    }
  end

  def replay(json_entries) when is_list(json_entries) do
    Enum.map(json_entries, fn raw ->
      decoded = decode!(raw)
      {:replayed, decoded["event_type"], decoded["occurred_at"]}
    end)
  end

  def batch_log(events, actor) do
    events
    |> Enum.take(@batch_flush_limit)
    |> Enum.map(fn {type, ctx} -> log_event(type, actor, ctx) end)
  end

  defp infer_severity(event_type) do
    cond do
      event_type in [:login_failed, :unauthorized_access] -> :warning
      event_type in [:data_deleted, :user_suspended]      -> :error
      event_type in [:system_breach, :data_exfiltration]  -> :critical
      event_type in [:login_succeeded, :record_viewed]    -> :info
      true                                                -> :debug
    end
  end

  defp emit(entry) do
    {:ok, entry}
  end
end
```
