**File:** `example_good_1180.md`

```elixir
defmodule LogParser.Record do
  @moduledoc "Represents a single structured log entry parsed from a raw log line."

  @enforce_keys [:timestamp, :level, :message, :source]
  defstruct [:timestamp, :level, :message, :source, :trace_id, :fields]

  @type level :: :debug | :info | :warning | :error | :critical
  @type t :: %__MODULE__{
          timestamp: DateTime.t(),
          level: level(),
          message: String.t(),
          source: String.t(),
          trace_id: String.t() | nil,
          fields: map()
        }
end

defmodule LogParser.LineParser do
  @moduledoc """
  Parses individual log lines in the structured JSON log format produced
  by the application's Logger backend.
  """

  alias LogParser.Record

  @level_map %{
    "debug" => :debug,
    "info" => :info,
    "warning" => :warning,
    "warn" => :warning,
    "error" => :error,
    "critical" => :critical
  }

  @spec parse(String.t()) :: {:ok, Record.t()} | {:error, :unparseable}
  def parse(line) when is_binary(line) do
    trimmed = String.trim(line)

    with {:ok, raw} <- Jason.decode(trimmed),
         {:ok, record} <- build_record(raw) do
      {:ok, record}
    else
      _ -> {:error, :unparseable}
    end
  end

  defp build_record(raw) when is_map(raw) do
    with {:ok, timestamp} <- parse_timestamp(raw["timestamp"]),
         {:ok, level} <- parse_level(raw["level"]),
         {:ok, message} <- require_string(raw["message"]),
         {:ok, source} <- require_string(raw["source"]) do
      {:ok, %Record{
        timestamp: timestamp,
        level: level,
        message: message,
        source: source,
        trace_id: raw["trace_id"],
        fields: Map.drop(raw, ~w(timestamp level message source trace_id))
      }}
    end
  end

  defp build_record(_raw), do: {:error, :unparseable}

  defp parse_timestamp(nil), do: {:error, :missing_timestamp}
  defp parse_timestamp(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp parse_level(nil), do: {:error, :missing_level}
  defp parse_level(raw) when is_binary(raw) do
    case Map.fetch(@level_map, String.downcase(raw)) do
      {:ok, level} -> {:ok, level}
      :error -> {:error, {:unknown_level, raw}}
    end
  end

  defp require_string(val) when is_binary(val) and val != "", do: {:ok, val}
  defp require_string(nil), do: {:error, :missing_field}
  defp require_string(_), do: {:error, :invalid_field}
end

defmodule LogParser do
  @moduledoc """
  Streams and parses a log file, yielding structured records and
  collecting parse errors for inspection. Operates in constant memory.
  """

  alias LogParser.{LineParser, Record}

  @type parse_stats :: %{
          total: non_neg_integer(),
          parsed: non_neg_integer(),
          failed: non_neg_integer()
        }

  @spec stream_records(String.t()) :: Enumerable.t()
  def stream_records(file_path) when is_binary(file_path) do
    file_path
    |> File.stream!([], :line)
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.flat_map(fn line ->
      case LineParser.parse(line) do
        {:ok, record} -> [record]
        {:error, _} -> []
      end
    end)
  end

  @spec filter_by_level(Enumerable.t(), [Record.level()]) :: Enumerable.t()
  def filter_by_level(records, levels) when is_list(levels) do
    Stream.filter(records, fn %Record{level: level} -> level in levels end)
  end

  @spec filter_since(Enumerable.t(), DateTime.t()) :: Enumerable.t()
  def filter_since(records, %DateTime{} = cutoff) do
    Stream.filter(records, fn %Record{timestamp: ts} ->
      DateTime.compare(ts, cutoff) in [:gt, :eq]
    end)
  end

  @spec parse_with_stats(String.t()) :: {[Record.t()], parse_stats()}
  def parse_with_stats(file_path) when is_binary(file_path) do
    {records, stats} =
      file_path
      |> File.stream!([], :line)
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.reduce({[], %{total: 0, parsed: 0, failed: 0}}, fn line, {recs, stats} ->
        updated_stats = %{stats | total: stats.total + 1}

        case LineParser.parse(line) do
          {:ok, record} ->
            {[record | recs], %{updated_stats | parsed: updated_stats.parsed + 1}}

          {:error, _} ->
            {recs, %{updated_stats | failed: updated_stats.failed + 1}}
        end
      end)

    {Enum.reverse(records), stats}
  end
end
```
