# File: `example_good_204.md`

```elixir
defmodule DataExport.NdjsonStreamer do
  @moduledoc """
  Streams large datasets to disk in newline-delimited JSON (NDJSON) format,
  keeping memory overhead constant regardless of dataset size.

  Records are fetched from the database in pages and written incrementally.
  Each record is passed through an optional transform function before
  serialisation, enabling field filtering or enrichment without
  buffering the entire result set.
  """

  @default_page_size 500

  @type transform_fn :: (map() -> map())
  @type stream_opts :: [
          page_size: pos_integer(),
          transform: transform_fn()
        ]

  @type stream_result ::
          {:ok, %{path: String.t(), record_count: non_neg_integer(), size_bytes: non_neg_integer()}}
          | {:error, :query_failed | :write_failed}

  @doc """
  Streams all records returned by `query_fn` to `destination_path` in NDJSON format.

  `query_fn/2` receives `(page, page_size)` and must return `{:ok, [map()]}` or
  `{:error, term()}`. It is called repeatedly until it returns an empty list.

  Options:
  - `:page_size` — records per database fetch (default: 500)
  - `:transform` — applied to each record before JSON serialisation

  Returns a summary of the written file on success.
  """
  @spec stream_to_file((pos_integer(), pos_integer() -> {:ok, [map()]} | {:error, term()}),
          String.t(),
          stream_opts()
        ) :: stream_result()
  def stream_to_file(query_fn, destination_path, opts \\ [])
      when is_function(query_fn, 2) and is_binary(destination_path) do
    page_size = Keyword.get(opts, :page_size, @default_page_size)
    transform = Keyword.get(opts, :transform, &Function.identity/1)

    case File.open(destination_path, [:write, :utf8]) do
      {:ok, file} -> stream_pages(file, query_fn, transform, page_size, destination_path)
      {:error, _reason} -> {:error, :write_failed}
    end
  end

  defp stream_pages(file, query_fn, transform, page_size, path) do
    result = stream_loop(file, query_fn, transform, page_size, 1, 0)
    File.close(file)

    case result do
      {:ok, count} ->
        size = File.stat!(path).size
        {:ok, %{path: path, record_count: count, size_bytes: size}}

      {:error, _} = error ->
        File.rm(path)
        error
    end
  end

  defp stream_loop(file, query_fn, transform, page_size, page, total_count) do
    case query_fn.(page, page_size) do
      {:ok, []} ->
        {:ok, total_count}

      {:ok, records} ->
        case write_records(file, records, transform) do
          :ok ->
            count = total_count + length(records)

            if length(records) < page_size do
              {:ok, count}
            else
              stream_loop(file, query_fn, transform, page_size, page + 1, count)
            end

          {:error, _} ->
            {:error, :write_failed}
        end

      {:error, _reason} ->
        {:error, :query_failed}
    end
  end

  defp write_records(file, records, transform) do
    Enum.reduce_while(records, :ok, fn record, _acc ->
      record
      |> transform.()
      |> Jason.encode()
      |> write_line(file)
    end)
  end

  defp write_line({:ok, json_string}, file) do
    case IO.write(file, json_string <> "\n") do
      :ok -> {:cont, :ok}
      {:error, _reason} -> {:halt, {:error, :write_failed}}
    end
  end

  defp write_line({:error, _encode_error}, _file) do
    {:halt, {:error, :write_failed}}
  end

  @doc """
  Counts the number of lines in an NDJSON file, which equals the number
  of records it contains.

  Returns `{:ok, count}` or `{:error, :not_found}`.
  """
  @spec count_records(String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def count_records(path) when is_binary(path) do
    case File.open(path, [:read]) do
      {:ok, file} ->
        count = count_lines(file, 0)
        File.close(file)
        {:ok, count}

      {:error, :enoent} ->
        {:error, :not_found}
    end
  end

  defp count_lines(file, count) do
    case IO.read(file, :line) do
      :eof -> count
      {:error, _} -> count
      _line -> count_lines(file, count + 1)
    end
  end
end
```
