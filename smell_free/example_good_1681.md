```elixir
defmodule Logging.StructuredLogger do
  @moduledoc """
  A structured logging façade that enriches every log entry with process
  context, request metadata, and a trace ID. Emits JSON-serialisable maps
  to the underlying Logger backend for ingestion by log aggregators.
  """

  require Logger

  @type log_level :: :debug | :info | :warn | :error
  @type log_context :: map()
  @type log_entry :: map()

  @context_key :structured_log_context

  @spec set_context(log_context()) :: :ok
  def set_context(context) when is_map(context) do
    existing = Process.get(@context_key, %{})
    Process.put(@context_key, Map.merge(existing, context))
    :ok
  end

  @spec clear_context() :: :ok
  def clear_context do
    Process.delete(@context_key)
    :ok
  end

  @spec with_context(log_context(), (-> result)) :: result when result: term()
  def with_context(context, fun) when is_function(fun, 0) do
    set_context(context)

    try do
      fun.()
    after
      clear_context()
    end
  end

  @spec debug(String.t(), map()) :: :ok
  def debug(message, fields \\ %{}), do: emit(:debug, message, fields)

  @spec info(String.t(), map()) :: :ok
  def info(message, fields \\ %{}), do: emit(:info, message, fields)

  @spec warn(String.t(), map()) :: :ok
  def warn(message, fields \\ %{}), do: emit(:warn, message, fields)

  @spec error(String.t(), map()) :: :ok
  def error(message, fields \\ %{}), do: emit(:error, message, fields)

  @spec log_exception(Exception.t(), list(), map()) :: :ok
  def log_exception(exception, stacktrace, fields \\ %{}) do
    error(Exception.message(exception), Map.merge(fields, %{
      exception_type: exception.__struct__ |> to_string(),
      stacktrace: Exception.format_stacktrace(stacktrace)
    }))
  end

  @spec emit(log_level(), String.t(), map()) :: :ok
  defp emit(level, message, fields) do
    entry = build_entry(level, message, fields)
    log_serialised(level, entry)
  end

  @spec build_entry(log_level(), String.t(), map()) :: log_entry()
  defp build_entry(level, message, fields) do
    context = Process.get(@context_key, %{})

    base = %{
      level: level,
      message: message,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      node: to_string(node()),
      pid: inspect(self())
    }

    base
    |> Map.merge(context)
    |> Map.merge(fields)
  end

  @spec log_serialised(log_level(), log_entry()) :: :ok
  defp log_serialised(level, entry) do
    serialised = Jason.encode!(entry)

    case level do
      :debug -> Logger.debug(serialised)
      :info -> Logger.info(serialised)
      :warn -> Logger.warning(serialised)
      :error -> Logger.error(serialised)
    end

    :ok
  end
end
```
