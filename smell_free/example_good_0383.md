```elixir
defmodule Exports.CsvExporter do
  @moduledoc """
  Streams arbitrarily large Ecto result sets to disk as CSV without
  loading the entire dataset into memory. Rows are fetched in configurable
  chunks via `Repo.stream/2`, encoded, and written incrementally to a
  temporary file. The caller receives a path to the completed file.

  Streaming is wrapped in a transaction as required by `Repo.stream/2`.
  The temporary file is written to a configurable directory and the caller
  is responsible for cleanup after consumption.
  """

  alias NimbleCSV.RFC4180, as: CSV
  import Ecto.Query

  require Logger

  @type export_opts :: [
          chunk_size: pos_integer(),
          output_dir: binary(),
          filename: binary()
        ]

  @default_chunk_size 500
  @default_output_dir System.tmp_dir!()

  @doc """
  Exports `queryable` rows to a CSV file, using `headers` as the first row
  and `row_fn` to transform each struct into a list of string values.
  Returns `{:ok, file_path}` or `{:error, reason}`.
  """
  @spec export(
          Ecto.Queryable.t(),
          [String.t()],
          (struct() -> [String.t()]),
          module(),
          export_opts()
        ) :: {:ok, binary()} | {:error, term()}
  def export(queryable, headers, row_fn, repo, opts \\ [])
      when is_list(headers) and is_function(row_fn, 1) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    output_dir = Keyword.get(opts, :output_dir, @default_output_dir)
    filename = Keyword.get(opts, :filename, default_filename())
    file_path = Path.join(output_dir, filename)

    with :ok <- File.mkdir_p(output_dir),
         {:ok, file} <- File.open(file_path, [:write, :utf8]),
         :ok <- stream_to_file(queryable, headers, row_fn, repo, file, chunk_size) do
      File.close(file)
      Logger.info("CSV export complete", path: file_path)
      {:ok, file_path}
    else
      {:error, reason} = err ->
        Logger.error("CSV export failed", reason: inspect(reason))
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp stream_to_file(queryable, headers, row_fn, repo, file, chunk_size) do
    header_row = CSV.dump_to_iodata([headers])
    IO.write(file, header_row)

    repo.transaction(fn ->
      queryable
      |> repo.stream(max_rows: chunk_size)
      |> Stream.map(row_fn)
      |> Stream.chunk_every(chunk_size)
      |> Enum.each(fn chunk ->
        iodata = CSV.dump_to_iodata(chunk)
        IO.write(file, iodata)
      end)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_filename do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    "export_#{timestamp}.csv"
  end
end

defmodule Exports.OrderExporter do
  @moduledoc """
  Specialised exporter for the `Order` schema. Defines the column headers
  and the row transformation function, then delegates to `CsvExporter`.
  Decouples export format decisions from the generic streaming machinery.
  """

  alias Exports.CsvExporter
  alias Commerce.{Order, Repo}

  @headers ~w[id customer_id status total_cents currency placed_at]

  @doc """
  Exports all orders placed within the given `date_range` to a CSV file.
  Returns `{:ok, file_path}` or `{:error, reason}`.
  """
  @spec export_range({Date.t(), Date.t()}, CsvExporter.export_opts()) ::
          {:ok, binary()} | {:error, term()}
  def export_range({from, until}, opts \\ []) do
    query =
      from(o in Order,
        where: o.placed_at >= ^DateTime.new!(from, ~T[00:00:00], "Etc/UTC"),
        where: o.placed_at <= ^DateTime.new!(until, ~T[23:59:59], "Etc/UTC"),
        order_by: [asc: o.placed_at]
      )

    CsvExporter.export(query, @headers, &to_row/1, Repo, opts)
  end

  defp to_row(%Order{} = order) do
    [
      order.id,
      order.customer_id,
      to_string(order.status),
      to_string(order.total_cents),
      order.currency,
      DateTime.to_iso8601(order.placed_at)
    ]
  end
end
```
