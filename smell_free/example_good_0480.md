```elixir
defmodule Ndjson.ParseResult do
  @moduledoc false

  @type t :: %__MODULE__{
          records: [map()],
          errors: [{non_neg_integer(), String.t()}],
          line_count: non_neg_integer()
        }

  defstruct [records: [], errors: [], line_count: 0]
end

defmodule Ndjson.Parser do
  @moduledoc """
  Parses newline-delimited JSON (NDJSON / JSON Lines) input where each
  line is an independent JSON object.

  Parse errors on individual lines are collected and returned alongside
  successfully parsed records rather than halting the stream. This makes
  the parser resilient for bulk-import scenarios where a few malformed
  lines should not discard an entire file.
  """

  alias Ndjson.ParseResult

  @spec parse(String.t()) :: ParseResult.t()
  def parse(input) when is_binary(input) do
    input
    |> split_lines()
    |> Enum.with_index(1)
    |> Enum.reduce(%ParseResult{}, &parse_line/2)
    |> finalize()
  end

  @spec parse_stream(Enumerable.t()) :: Enumerable.t()
  def parse_stream(line_stream) do
    Stream.map(line_stream, fn line ->
      case Jason.decode(String.trim(line)) do
        {:ok, record} when is_map(record) -> {:ok, record}
        {:ok, _non_map} -> {:error, :not_an_object}
        {:error, %Jason.DecodeError{} = e} -> {:error, Exception.message(e)}
      end
    end)
  end

  @spec parse_file(Path.t()) :: {:ok, ParseResult.t()} | {:error, :file_not_found}
  def parse_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, parse(content)}
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  @spec records_only(ParseResult.t()) :: [map()]
  def records_only(%ParseResult{records: records}), do: records

  @spec valid?(ParseResult.t()) :: boolean()
  def valid?(%ParseResult{errors: []}), do: true
  def valid?(%ParseResult{}), do: false

  defp split_lines(input) do
    input
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "//")))
  end

  defp parse_line({line, line_number}, %ParseResult{} = acc) do
    updated = %{acc | line_count: acc.line_count + 1}

    case Jason.decode(line) do
      {:ok, record} when is_map(record) ->
        %{updated | records: [record | acc.records]}

      {:ok, _non_map} ->
        error = {line_number, "expected a JSON object, got a non-object value"}
        %{updated | errors: [error | acc.errors]}

      {:error, %Jason.DecodeError{} = e} ->
        %{updated | errors: [{line_number, Exception.message(e)} | acc.errors]}
    end
  end

  defp finalize(%ParseResult{} = result) do
    %{result |
      records: Enum.reverse(result.records),
      errors: Enum.reverse(result.errors)
    }
  end
end
```
