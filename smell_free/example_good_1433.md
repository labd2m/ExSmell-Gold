```elixir
defmodule Exports.Formatter do
  @moduledoc """
  Serialises a list of data records into a requested export format.
  Each format is handled by a dedicated private module, keeping the
  public interface uniform and format-specific logic fully isolated.
  """

  @type row :: map()
  @type format :: :csv | :json | :ndjson | :tsv
  @type format_result :: {:ok, binary()} | {:error, atom()}

  @spec format(format(), [row()], keyword()) :: format_result()
  def format(:csv, rows, opts) when is_list(rows) do
    headers = Keyword.get(opts, :headers, auto_headers(rows))
    CsvFormat.encode(rows, headers)
  end

  def format(:tsv, rows, opts) when is_list(rows) do
    headers = Keyword.get(opts, :headers, auto_headers(rows))
    TsvFormat.encode(rows, headers)
  end

  def format(:json, rows, _opts) when is_list(rows) do
    case Jason.encode(rows) do
      {:ok, binary} -> {:ok, binary}
      {:error, _} -> {:error, :json_encode_failed}
    end
  end

  def format(:ndjson, rows, _opts) when is_list(rows) do
    NdjsonFormat.encode(rows)
  end

  def format(unknown, _rows, _opts), do: {:error, {:unsupported_format, unknown}}

  @spec auto_headers([row()]) :: [String.t()]
  defp auto_headers([]), do: []

  defp auto_headers([first | _]) do
    first |> Map.keys() |> Enum.map(&to_string/1)
  end

  defmodule CsvFormat do
    @moduledoc false

    @spec encode([map()], [String.t()]) :: {:ok, binary()} | {:error, atom()}
    def encode(rows, headers) do
      header_line = Enum.join(headers, ",")

      data_lines =
        Enum.map(rows, fn row ->
          headers
          |> Enum.map(&escape_csv(to_string(Map.get(row, String.to_existing_atom(&1), ""))))
          |> Enum.join(",")
        end)

      {:ok, Enum.join([header_line | data_lines], "\n")}
    rescue
      _ -> {:error, :csv_encode_failed}
    end

    defp escape_csv(value) do
      if String.contains?(value, [",", "\"", "\n"]) do
        "\"#{String.replace(value, "\"", "\"\"")}\""
      else
        value
      end
    end
  end

  defmodule TsvFormat do
    @moduledoc false

    @spec encode([map()], [String.t()]) :: {:ok, binary()} | {:error, atom()}
    def encode(rows, headers) do
      header_line = Enum.join(headers, "\t")

      data_lines =
        Enum.map(rows, fn row ->
          headers
          |> Enum.map(&to_string(Map.get(row, String.to_existing_atom(&1), "")))
          |> Enum.map(&String.replace(&1, "\t", " "))
          |> Enum.join("\t")
        end)

      {:ok, Enum.join([header_line | data_lines], "\n")}
    rescue
      _ -> {:error, :tsv_encode_failed}
    end
  end

  defmodule NdjsonFormat do
    @moduledoc false

    @spec encode([map()]) :: {:ok, binary()} | {:error, atom()}
    def encode(rows) do
      lines =
        Enum.reduce_while(rows, [], fn row, acc ->
          case Jason.encode(row) do
            {:ok, line} -> {:cont, [line | acc]}
            {:error, _} -> {:halt, {:error, :ndjson_encode_failed}}
          end
        end)

      case lines do
        {:error, _} = err -> err
        lines -> {:ok, lines |> Enum.reverse() |> Enum.join("\n")}
      end
    end
  end
end
```
