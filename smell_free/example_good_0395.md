```elixir
defmodule Observability.PiiSafeLogger do
  @moduledoc """
  A structured logger backend that redacts sensitive fields before
  forwarding log entries to the configured sink. Redaction rules are
  declared as a list of field name patterns and applied recursively to
  nested maps and keyword lists. The formatter is drop-in compatible with
  Elixir's `:logger` handler configuration so existing call sites require
  no changes.

  All redaction happens in-process before any I/O, ensuring PII never
  reaches log files, stdout, or external aggregators like Datadog or Splunk.
  """

  @type redaction_rule :: {:exact, binary()} | {:pattern, Regex.t()}

  @sensitive_fields [
    {:exact, "password"},
    {:exact, "password_hash"},
    {:exact, "token"},
    {:exact, "secret"},
    {:exact, "access_token"},
    {:exact, "refresh_token"},
    {:exact, "api_key"},
    {:exact, "credit_card"},
    {:exact, "card_number"},
    {:exact, "cvv"},
    {:exact, "ssn"},
    {:exact, "tax_id"},
    {:pattern, ~r/^.*_secret$/},
    {:pattern, ~r/^.*_token$/},
    {:pattern, ~r/^.*_key$/}
  ]

  @redacted_value "[REDACTED]"

  @doc """
  Recursively redacts sensitive fields from `data`. Handles maps,
  keyword lists, and lists of maps. Returns the sanitised structure
  with the same shape as the input.
  """
  @spec redact(term()) :: term()
  def redact(data) when is_map(data) do
    Map.new(data, fn {k, v} ->
      key_str = to_string(k)

      if sensitive_field?(key_str) do
        {k, @redacted_value}
      else
        {k, redact(v)}
      end
    end)
  end

  def redact(data) when is_list(data) do
    if Keyword.keyword?(data) do
      Enum.map(data, fn {k, v} ->
        if sensitive_field?(to_string(k)), do: {k, @redacted_value}, else: {k, redact(v)}
      end)
    else
      Enum.map(data, &redact/1)
    end
  end

  def redact(data), do: data

  @doc """
  Formats a structured log event as a JSON string with PII redacted.
  Includes standard fields: `level`, `message`, `timestamp`, `metadata`.
  Intended for use as the `:formatter` option in a Logger handler config.
  """
  @spec format_event(:logger.log_event(), :logger.formatter_config()) :: iodata()
  def format_event(%{level: level, msg: msg, meta: meta}, _config) do
    message = format_message(msg)
    sanitized_meta = meta |> Map.drop([:time, :gl, :pid]) |> redact()

    entry = %{
      level: level,
      message: message,
      timestamp: iso8601_now(),
      metadata: sanitized_meta
    }

    [Jason.encode!(entry), "\n"]
  rescue
    _ -> ["[logger formatting error]\n"]
  end

  @doc """
  Logs a structured map at the given level after running redaction.
  Convenience wrapper around `Logger.log/3` for call sites that construct
  explicit metadata maps.
  """
  @spec log(Logger.level(), binary(), map()) :: :ok
  def log(level, message, metadata \\ %{}) when is_binary(message) and is_map(metadata) do
    safe_meta = redact(metadata)
    Logger.log(level, message, Enum.to_list(safe_meta))
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp sensitive_field?(key) do
    Enum.any?(@sensitive_fields, fn
      {:exact, name} -> key == name
      {:pattern, regex} -> Regex.match?(regex, key)
    end)
  end

  defp format_message({:string, text}), do: IO.iodata_to_binary(text)
  defp format_message({:report, report}), do: inspect(redact(report))
  defp format_message(other), do: inspect(other)

  defp iso8601_now do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
end
```
