**File:** `example_good_1402.md`

```elixir
defmodule StructuredLogger.Entry do
  @moduledoc "A single structured log entry with typed fields."

  @enforce_keys [:level, :message, :timestamp, :source]
  defstruct [:level, :message, :timestamp, :source, :trace_id, :fields]

  @type level :: :debug | :info | :warning | :error | :critical
  @type t :: %__MODULE__{
          level: level(),
          message: String.t(),
          timestamp: DateTime.t(),
          source: String.t(),
          trace_id: String.t() | nil,
          fields: map()
        }

  @spec new(level(), String.t(), String.t(), keyword()) :: t()
  def new(level, message, source, opts \\ []) do
    %__MODULE__{
      level: level,
      message: message,
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      source: source,
      trace_id: Keyword.get(opts, :trace_id),
      fields: Keyword.get(opts, :fields, %{})
    }
  end
end

defmodule StructuredLogger.Formatter do
  @moduledoc "Behaviour for log entry formatters."

  alias StructuredLogger.Entry

  @doc "Serializes a log entry into a binary string."
  @callback format(Entry.t()) :: binary()
end

defmodule StructuredLogger.Formatters.JSON do
  @moduledoc "Formats log entries as JSON objects with ISO 8601 timestamps."

  @behaviour StructuredLogger.Formatter

  alias StructuredLogger.Entry

  @impl StructuredLogger.Formatter
  def format(%Entry{} = entry) do
    payload =
      %{
        level: entry.level,
        message: entry.message,
        timestamp: DateTime.to_iso8601(entry.timestamp),
        source: entry.source
      }
      |> maybe_put(:trace_id, entry.trace_id)
      |> Map.merge(entry.fields)

    Jason.encode!(payload)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule StructuredLogger.Formatters.Logfmt do
  @moduledoc "Formats log entries in the logfmt key=value style."

  @behaviour StructuredLogger.Formatter

  alias StructuredLogger.Entry

  @impl StructuredLogger.Formatter
  def format(%Entry{} = entry) do
    base = [
      "ts=#{DateTime.to_iso8601(entry.timestamp)}",
      "level=#{entry.level}",
      "source=#{entry.source}",
      "msg=#{inspect(entry.message)}"
    ]

    trace_part =
      if entry.trace_id, do: ["trace_id=#{entry.trace_id}"], else: []

    fields_part =
      Enum.map(entry.fields, fn {k, v} -> "#{k}=#{inspect(v)}" end)

    Enum.join(base ++ trace_part ++ fields_part, " ")
  end
end

defmodule StructuredLogger.Sink do
  @moduledoc "Behaviour for log sinks that receive formatted entries."

  @doc "Writes a formatted log line to the sink destination."
  @callback write(binary()) :: :ok
end

defmodule StructuredLogger.Sinks.Stdout do
  @moduledoc "Writes formatted log lines to standard output."
  @behaviour StructuredLogger.Sink
  @impl StructuredLogger.Sink
  def write(line), do: IO.puts(line)
end

defmodule StructuredLogger do
  @moduledoc """
  A structured logger that routes entries through a formatter and one
  or more sinks. Filters entries below the configured minimum level.
  """

  alias StructuredLogger.Entry

  @level_order ~w(debug info warning error critical)a

  @type config :: %{
          min_level: Entry.level(),
          formatter: module(),
          sinks: [module()]
        }

  @spec log(Entry.level(), String.t(), String.t(), config(), keyword()) :: :ok
  def log(level, message, source, config, opts \\ []) do
    if level_at_or_above?(level, config.min_level) do
      entry = Entry.new(level, message, source, opts)
      formatted = config.formatter.format(entry)
      Enum.each(config.sinks, &(&1.write(formatted)))
    end

    :ok
  end

  @spec debug(String.t(), String.t(), config(), keyword()) :: :ok
  def debug(msg, source, config, opts \\ []), do: log(:debug, msg, source, config, opts)

  @spec info(String.t(), String.t(), config(), keyword()) :: :ok
  def info(msg, source, config, opts \\ []), do: log(:info, msg, source, config, opts)

  @spec warning(String.t(), String.t(), config(), keyword()) :: :ok
  def warning(msg, source, config, opts \\ []), do: log(:warning, msg, source, config, opts)

  @spec error(String.t(), String.t(), config(), keyword()) :: :ok
  def error(msg, source, config, opts \\ []), do: log(:error, msg, source, config, opts)

  defp level_at_or_above?(level, min_level) do
    level_index(level) >= level_index(min_level)
  end

  defp level_index(level) do
    Enum.find_index(@level_order, &(&1 == level)) || 0
  end
end
```
