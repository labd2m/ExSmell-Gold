# Annotated Example 08

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `StructuredLogger.log/3`
- **Affected functions:** `log/3`
- **Short explanation:** The library reads `:output_format` and `:timestamp_precision` from the Application Environment. Applications that need to log in JSON format to a file and in plain text to stdout simultaneously cannot do so through this library without breaking its global config assumption.

```elixir
defmodule StructuredLogger do
  @moduledoc """
  A structured logging library that formats log entries in JSON or
  plain-text formats. Intended for use in web apps, background workers,
  and data pipelines that need consistent, parseable log output.
  """

  @valid_formats ~w(json plain logfmt)a
  @valid_precisions ~w(second millisecond microsecond)a

  defmodule Entry do
    defstruct [:level, :message, :timestamp, :context, :trace_id]
  end

  @doc """
  Emits a log entry at the given level with optional context metadata.

  `level` is one of `:debug`, `:info`, `:warning`, `:error`.
  `message` is the log message string.
  `context` is an optional map of additional fields.
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because output_format and timestamp_precision
  # are fetched from the Application Environment rather than accepted as
  # options. An application that wants JSON-formatted logs for a monitoring
  # pipeline and plain-text logs in a developer console cannot call log/3
  # with different formats in different parts of the code.
  def log(level, message, context \\ %{}) when is_atom(level) and is_binary(message) do
    format    = Application.fetch_env!(:structured_logger, :output_format)
    precision = Application.fetch_env!(:structured_logger, :timestamp_precision)

    unless format in @valid_formats do
      raise ArgumentError, "Invalid log format: #{format}"
    end

    unless precision in @valid_precisions do
      raise ArgumentError, "Invalid timestamp precision: #{precision}"
    end

    entry = %Entry{
      level:     level,
      message:   message,
      timestamp: build_timestamp(precision),
      context:   context,
      trace_id:  Map.get(context, :trace_id)
    }

    formatted = render_entry(entry, format)
    IO.puts(formatted)

    {:ok, entry}
  end
  # VALIDATION: SMELL END

  @doc """
  Convenience functions for each log level.
  """
  def debug(message, context \\ %{}), do: log(:debug, message, context)
  def info(message, context \\ %{}),  do: log(:info, message, context)
  def warn(message, context \\ %{}),  do: log(:warning, message, context)
  def error(message, context \\ %{}), do: log(:error, message, context)

  @doc """
  Wraps a function call and logs its duration at `:info` level.
  """
  def timed(label, context \\ %{}, fun) when is_function(fun, 0) do
    started_at = System.monotonic_time(:millisecond)

    result = fun.()

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    log(:info, "#{label} completed", Map.put(context, :elapsed_ms, elapsed_ms))

    result
  end

  # --- Private helpers ---

  defp build_timestamp(:second),      do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp build_timestamp(:millisecond), do: DateTime.utc_now() |> DateTime.truncate(:millisecond)
  defp build_timestamp(:microsecond), do: DateTime.utc_now()

  defp render_entry(entry, :json) do
    map = %{
      level:     entry.level,
      message:   entry.message,
      timestamp: DateTime.to_iso8601(entry.timestamp),
      trace_id:  entry.trace_id
    }
    |> Map.merge(entry.context)
    |> Map.reject(fn {_, v} -> is_nil(v) end)

    Jason.encode!(map)
  end

  defp render_entry(entry, :plain) do
    ts     = DateTime.to_iso8601(entry.timestamp)
    level  = entry.level |> to_string() |> String.upcase() |> String.pad_trailing(7)
    ctx    = if map_size(entry.context) > 0, do: " #{inspect(entry.context)}", else: ""
    "#{ts} [#{level}] #{entry.message}#{ctx}"
  end

  defp render_entry(entry, :logfmt) do
    fields = [
      "ts=#{DateTime.to_iso8601(entry.timestamp)}",
      "level=#{entry.level}",
      "msg=#{inspect(entry.message)}"
    ]

    context_fields =
      entry.context
      |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)

    Enum.join(fields ++ context_fields, " ")
  end
end
```
