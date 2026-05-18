```elixir
defmodule Observability.LogSanitizer do
  @moduledoc """
  Sanitizes and normalises structured log fields before they are forwarded
  to external log aggregation services such as Datadog or Splunk.
  Prevents accidental leakage of sensitive data and enforces field size limits.
  """

  @max_message_bytes 4_096
  @max_tag_length 128
  @max_user_id_length 64
  @sensitive_keys ~w(password token secret api_key authorization)

  defmacro truncate_field(value, max_bytes) do
    quote do
      v = unquote(value)
      limit = unquote(max_bytes)

      if byte_size(v) > limit do
        binary_part(v, 0, limit) <> "…"
      else
        v
      end
    end
  end

  def sanitize(log_entry) when is_map(log_entry) do
    require Observability.LogSanitizer

    log_entry
    |> redact_sensitive_keys()
    |> Map.update(:message, "", fn msg ->
      Observability.LogSanitizer.truncate_field(to_string(msg), @max_message_bytes)
    end)
    |> Map.update(:user_id, nil, fn uid ->
      if uid do
        Observability.LogSanitizer.truncate_field(to_string(uid), @max_user_id_length)
      end
    end)
    |> normalise_tags()
  end

  def sanitize_batch(entries) when is_list(entries) do
    Enum.map(entries, &sanitize/1)
  end

  defp redact_sensitive_keys(entry) do
    Enum.reduce(@sensitive_keys, entry, fn key, acc ->
      atom_key = String.to_atom(key)

      acc
      |> Map.replace(key, "[REDACTED]")
      |> Map.replace(atom_key, "[REDACTED]")
    end)
  end

  defp normalise_tags(entry) do
    require Observability.LogSanitizer

    case Map.get(entry, :tags) do
      nil ->
        entry

      tags when is_list(tags) ->
        clean_tags =
          tags
          |> Enum.map(&to_string/1)
          |> Enum.map(fn t ->
            Observability.LogSanitizer.truncate_field(t, @max_tag_length)
          end)
          |> Enum.uniq()

        Map.put(entry, :tags, clean_tags)

      tags when is_map(tags) ->
        clean =
          Map.new(tags, fn {k, v} ->
            {k, Observability.LogSanitizer.truncate_field(to_string(v), @max_tag_length)}
          end)

        Map.put(entry, :tags, clean)
    end
  end

  def add_service_context(entry, service_name, environment) do
    Map.merge(entry, %{
      service: service_name,
      environment: environment,
      host: System.get_env("HOSTNAME", "unknown"),
      app_version: Application.spec(:my_app, :vsn) |> to_string()
    })
  end

  def to_json(entry) do
    Jason.encode!(entry)
  end
end
```
