```elixir
defmodule ImportPipeline.Source do
  @moduledoc """
  Behaviour for pluggable data sources feeding the import pipeline.
  Implementations must produce enumerable batches of raw maps.
  """

  @callback open(config :: map()) :: {:ok, term()} | {:error, term()}
  @callback next_batch(handle :: term(), size :: pos_integer()) ::
              {:ok, [map()], term()} | {:done, [map()]} | {:error, term()}
  @callback close(handle :: term()) :: :ok
end

defmodule ImportPipeline.Sources.S3Csv do
  @behaviour ImportPipeline.Source

  @moduledoc """
  Reads CSV rows from an S3 object in streaming batches.
  """

  @impl ImportPipeline.Source
  def open(%{bucket: bucket, key: key, region: region}) do
    case ExAws.S3.get_object(bucket, key) |> ExAws.request(region: region) do
      {:ok, %{body: body}} ->
        lines = String.split(body, "\n", trim: true)
        [header | data] = lines
        columns = header |> String.split(",") |> Enum.map(&String.trim/1)
        {:ok, {columns, data}}

      {:error, reason} ->
        {:error, {:s3_read_failed, reason}}
    end
  end

  @impl ImportPipeline.Source
  def next_batch({_columns, []}, _size), do: {:done, []}

  def next_batch({columns, lines}, size) do
    {batch_lines, remaining} = Enum.split(lines, size)

    rows =
      Enum.map(batch_lines, fn line ->
        values = line |> String.split(",") |> Enum.map(&String.trim/1)
        Enum.zip(columns, values) |> Map.new()
      end)

    if remaining == [] do
      {:done, rows}
    else
      {:ok, rows, {columns, remaining}}
    end
  end

  @impl ImportPipeline.Source
  def close(_handle), do: :ok
end

defmodule ImportPipeline.Runner do
  @moduledoc """
  Orchestrates a full import run by streaming batches from a source,
  applying a transformation function, and writing to a sink function.
  Returns a summary of total records processed and any per-record errors.
  """

  @type transform_fn :: ([map()] -> {:ok, [map()]} | {:error, term()})
  @type sink_fn :: ([map()] -> :ok | {:error, term()})
  @type run_summary :: %{processed: non_neg_integer(), errors: [term()]}

  @spec run(module(), map(), transform_fn(), sink_fn(), keyword()) :: {:ok, run_summary()}
  def run(source_module, source_config, transform_fn, sink_fn, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 200)

    with {:ok, handle} <- source_module.open(source_config) do
      result = stream_batches(source_module, handle, batch_size, transform_fn, sink_fn,
                              %{processed: 0, errors: []})
      source_module.close(handle)
      {:ok, result}
    end
  end

  defp stream_batches(source, handle, size, transform, sink, acc) do
    case source.next_batch(handle, size) do
      {:done, []} ->
        acc

      {:done, rows} ->
        acc = process_batch(rows, transform, sink, acc)
        acc

      {:ok, rows, new_handle} ->
        acc = process_batch(rows, transform, sink, acc)
        stream_batches(source, new_handle, size, transform, sink, acc)

      {:error, reason} ->
        %{acc | errors: acc.errors ++ [{:source_error, reason}]}
    end
  end

  defp process_batch(rows, transform, sink, acc) do
    case transform.(rows) do
      {:ok, transformed} ->
        case sink.(transformed) do
          :ok -> %{acc | processed: acc.processed + length(transformed)}
          {:error, reason} -> %{acc | errors: acc.errors ++ [{:sink_error, reason}]}
        end

      {:error, reason} ->
        %{acc | errors: acc.errors ++ [{:transform_error, reason}]}
    end
  end
end
```
