```elixir
defmodule MyApp.DataExport.JSONStreamer do
  @moduledoc """
  Streams large Ecto query results as newline-delimited JSON (NDJSON) to
  any `IO.device/0`, including HTTP response bodies via Plug chunked transfer.
  Each row is encoded individually so that the encoder never holds more than
  one batch in memory at a time.

  Typical usage with a Plug response:

      conn = send_chunked(conn, 200)
      {:ok, _count} =
        MyApp.DataExport.JSONStreamer.stream_to(query, conn, encoder: &CustomEncoder.encode/1)
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo

  @batch_size 200

  @type row_encoder :: (map() -> map())

  @type opts :: [
          batch_size: pos_integer(),
          encoder: row_encoder()
        ]

  @doc """
  Streams all rows from `query` to `device` as NDJSON.
  Each row is passed through the optional `:encoder` function before
  JSON serialization. Returns `{:ok, total_rows_written}` on success.

  Must be called inside a `Repo.transaction/1` block when using `Repo.stream/2`.
  """
  @spec stream_to(Ecto.Query.t(), IO.device(), opts()) :: {:ok, non_neg_integer()}
  def stream_to(query, device, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @batch_size)
    encoder = Keyword.get(opts, :encoder, &identity/1)

    count =
      query
      |> Repo.stream(max_rows: batch_size)
      |> Stream.map(encoder)
      |> Stream.map(&Jason.encode!/1)
      |> Enum.reduce(0, fn json_line, acc ->
        write_line(device, json_line)
        acc + 1
      end)

    {:ok, count}
  end

  @doc """
  Streams rows from `query` and writes them to `file_path` as NDJSON.
  The file is created or truncated before streaming begins.
  Returns `{:ok, total_rows_written}` or `{:error, reason}`.
  """
  @spec stream_to_file(Ecto.Query.t(), String.t(), opts()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def stream_to_file(query, file_path, opts \\ []) when is_binary(file_path) do
    case File.open(file_path, [:write, :utf8]) do
      {:ok, device} ->
        result =
          Repo.transaction(fn ->
            {:ok, count} = stream_to(query, device, opts)
            count
          end)

        File.close(device)

        case result do
          {:ok, count} -> {:ok, count}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:file_open_failed, reason}}
    end
  end

  @doc """
  Produces a metadata header line as the first NDJSON record. Useful for
  streaming exports that consumers need to introspect without parsing all rows.
  """
  @spec write_header(IO.device(), map()) :: :ok
  def write_header(device, meta) when is_map(meta) do
    header = Map.put(meta, :_record_type, "header")
    write_line(device, Jason.encode!(header))
  end

  @spec write_line(IO.device(), String.t()) :: :ok
  defp write_line(device, json) do
    IO.write(device, json <> "\n")
  end

  @spec identity(term()) :: term()
  defp identity(value), do: value
end
```
