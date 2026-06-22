```elixir
defmodule Platform.StreamSink do
  @moduledoc """
  A behaviour and set of built-in sinks for streaming Ecto query results
  to various destinations: files, S3, HTTP endpoints, or custom outputs.

  Each sink implements `write_chunk/2` and `finalize/1`. The pipeline
  streams rows in configurable batches, calling the sink for each chunk.
  """

  @callback open(keyword()) :: {:ok, term()} | {:error, term()}
  @callback write_chunk(term(), [map()]) :: {:ok, term()} | {:error, term()}
  @callback finalize(term()) :: :ok | {:error, term()}

  @type sink :: module()
  @type run_result :: {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Streams `queryable` results through `sink`, writing in batches.
  Returns `{:ok, total_rows_written}` on completion.
  """
  @spec stream(Ecto.Queryable.t(), (struct() -> map()), sink(), keyword()) :: run_result()
  def stream(queryable, row_mapper, sink, opts \\ []) when is_function(row_mapper, 1) do
    batch_size = Keyword.get(opts, :batch_size, 500)
    sink_opts = Keyword.get(opts, :sink_opts, [])

    alias Platform.Repo

    with {:ok, state} <- sink.open(sink_opts) do
      result =
        Repo.transaction(fn ->
          queryable
          |> Repo.stream(max_rows: batch_size)
          |> Stream.map(row_mapper)
          |> Stream.chunk_every(batch_size)
          |> Enum.reduce_while({:ok, state, 0}, fn chunk, {:ok, current_state, count} ->
            case sink.write_chunk(current_state, chunk) do
              {:ok, new_state} -> {:cont, {:ok, new_state, count + length(chunk)}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        end, timeout: :infinity)

      case result do
        {:ok, {:ok, final_state, total}} ->
          case sink.finalize(final_state) do
            :ok -> {:ok, total}
            error -> error
          end

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end

defmodule Platform.StreamSink.CsvFile do
  @moduledoc "Sink that writes rows as CSV to a local file."

  @behaviour Platform.StreamSink

  alias NimbleCSV.RFC4180, as: CSV

  @impl Platform.StreamSink
  def open(opts) do
    path = Keyword.fetch!(opts, :path)
    headers = Keyword.get(opts, :headers, [])

    case File.open(path, [:write, :utf8]) do
      {:ok, file} ->
        if headers != [] do
          IO.write(file, CSV.dump_to_iodata([headers]))
        end
        {:ok, %{file: file, path: path}}

      {:error, reason} ->
        {:error, {:file_open_failed, reason}}
    end
  end

  @impl Platform.StreamSink
  def write_chunk(%{file: file} = state, rows) do
    rows_as_lists = Enum.map(rows, &Map.values/1)
    IO.write(file, CSV.dump_to_iodata(rows_as_lists))
    {:ok, state}
  rescue
    error -> {:error, error}
  end

  @impl Platform.StreamSink
  def finalize(%{file: file}) do
    File.close(file)
    :ok
  end
end

defmodule Platform.StreamSink.JsonLines do
  @moduledoc "Sink that writes rows as newline-delimited JSON (NDJSON) to a file."

  @behaviour Platform.StreamSink

  @impl Platform.StreamSink
  def open(opts) do
    path = Keyword.fetch!(opts, :path)
    case File.open(path, [:write, :utf8]) do
      {:ok, file} -> {:ok, %{file: file}}
      {:error, reason} -> {:error, {:file_open_failed, reason}}
    end
  end

  @impl Platform.StreamSink
  def write_chunk(%{file: file} = state, rows) do
    Enum.each(rows, fn row -> IO.write(file, Jason.encode!(row) <> "\n") end)
    {:ok, state}
  end

  @impl Platform.StreamSink
  def finalize(%{file: file}) do
    File.close(file)
    :ok
  end
end
```
