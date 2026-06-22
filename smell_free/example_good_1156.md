```elixir
defmodule DataImport.CsvProcessor do
  @moduledoc """
  Memory-efficient CSV processor using lazy Elixir streams.

  Large files are parsed row-by-row without loading their entire contents
  into memory. Each row is validated and transformed before being flushed
  to a configurable sink function in configurable batch sizes.

  The `:sink` option must be a function accepting a list of row maps and
  returning `:ok` or `{:error, reason}`. Failed rows are logged and counted
  without aborting the stream.
  """

  require Logger

  @type row_map :: %{optional(String.t()) => String.t()}
  @type sink_fn :: ([row_map()] -> :ok | {:error, term()})
  @type summary :: %{processed: non_neg_integer(), failed: non_neg_integer()}

  @default_batch_size 500

  @doc """
  Processes a CSV file at `path`, mapping columns to `headers`.

  Returns `{:ok, summary}` with processing counts, or `{:error, reason}`
  when the file cannot be opened.
  """
  @spec process_file(Path.t(), [String.t()], keyword()) ::
          {:ok, summary()} | {:error, term()}
  def process_file(path, headers, opts \\ [])
      when is_binary(path) and is_list(headers) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    sink = Keyword.fetch!(opts, :sink)

    with {:ok, stream} <- open_stream(path) do
      summary =
        stream
        |> Stream.map(&parse_row(&1, headers))
        |> Stream.map(&validate_row/1)
        |> Stream.chunk_every(batch_size)
        |> Stream.map(&flush_batch(&1, sink))
        |> Enum.reduce(%{processed: 0, failed: 0}, &merge_summary/2)

      {:ok, summary}
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp open_stream(path) do
    if File.exists?(path) do
      {:ok, path |> File.stream!() |> CSV.decode!(headers: false)}
    else
      {:error, {:file_not_found, path}}
    end
  end

  defp parse_row(raw_fields, headers) do
    if length(raw_fields) == length(headers) do
      {:ok, headers |> Enum.zip(raw_fields) |> Map.new()}
    else
      {:error, {:field_count_mismatch, %{expected: length(headers), got: length(raw_fields)}}}
    end
  end

  defp validate_row({:error, _} = error), do: error

  defp validate_row({:ok, row}) do
    required = ["id", "name", "email"]

    if Enum.all?(required, &(Map.get(row, &1, "") != "")) do
      {:ok, normalize_row(row)}
    else
      {:error, {:missing_required_fields, row}}
    end
  end

  defp normalize_row(row) do
    row
    |> Map.update("email", "", &String.downcase/1)
    |> Map.update("name", "", &String.trim/1)
  end

  defp flush_batch(rows, sink) do
    {valid, invalid} = Enum.split_with(rows, &match?({:ok, _}, &1))
    records = Enum.map(valid, fn {:ok, row} -> row end)

    log_invalid_rows(invalid)

    case sink.(records) do
      :ok ->
        %{processed: length(records), failed: length(invalid)}

      {:error, reason} ->
        Logger.error("Batch flush failed", reason: inspect(reason))
        %{processed: 0, failed: length(rows)}
    end
  end

  defp log_invalid_rows([]), do: :ok

  defp log_invalid_rows(invalid) do
    Enum.each(invalid, fn {:error, reason} ->
      Logger.warning("Skipping invalid row", reason: inspect(reason))
    end)
  end

  defp merge_summary(batch_summary, acc) do
    %{
      processed: acc.processed + batch_summary.processed,
      failed: acc.failed + batch_summary.failed
    }
  end
end
```
