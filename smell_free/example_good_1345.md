```elixir
defmodule Streaming.Source do
  @moduledoc """
  Behaviour for data streaming sources. Each source produces a lazy
  `Stream` of records and exposes its own connection lifecycle.
  Callers interact exclusively through this behaviour so adapters
  are swappable without touching pipeline code.
  """

  @type record :: map()
  @type source_opts :: keyword()

  @callback open(source_opts()) :: {:ok, term()} | {:error, atom()}
  @callback stream(term()) :: Enumerable.t()
  @callback close(term()) :: :ok
end

defmodule Streaming.Sources.DatabaseCursor do
  @moduledoc """
  A streaming source that pages through a database query using an Ecto
  cursor, yielding rows as individual maps. The cursor is held open for
  the lifetime of the stream and closed when consumption finishes.
  """

  @behaviour Streaming.Source

  @default_chunk_size 200

  @impl Streaming.Source
  def open(opts) when is_list(opts) do
    repo = Keyword.fetch!(opts, :repo)
    query = Keyword.fetch!(opts, :query)
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    {:ok, %{repo: repo, query: query, chunk_size: chunk_size}}
  rescue
    err -> {:error, {:open_failed, Exception.message(err)}}
  end

  @impl Streaming.Source
  def stream(%{repo: repo, query: query, chunk_size: chunk_size}) do
    repo.stream(query, max_rows: chunk_size)
    |> Stream.map(&Map.from_struct/1)
  end

  @impl Streaming.Source
  def close(_state), do: :ok
end

defmodule Streaming.Sources.FileLines do
  @moduledoc """
  A streaming source that reads a newline-delimited JSON file, yielding
  one decoded map per line. Malformed lines are skipped with a warning.
  """

  @behaviour Streaming.Source

  require Logger

  @impl Streaming.Source
  def open(opts) when is_list(opts) do
    path = Keyword.fetch!(opts, :path)

    if File.exists?(path) do
      {:ok, %{path: path}}
    else
      {:error, :file_not_found}
    end
  end

  @impl Streaming.Source
  def stream(%{path: path}) do
    path
    |> File.stream!([:utf8])
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.flat_map(&decode_line/1)
  end

  @impl Streaming.Source
  def close(_state), do: :ok

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) -> [map]
      {:ok, _} -> []
      {:error, _} ->
        Logger.warning("Skipping malformed NDJSON line", line_preview: String.slice(line, 0, 80))
        []
    end
  end
end

defmodule Streaming.Pipeline do
  @moduledoc """
  Runs a streaming source through a sequence of transformation steps
  and delivers records to a sink function. Each step is a plain
  one-arity function returning `{:ok, map()}` or `{:error, term()}`.
  Errors are collected per-record without aborting the stream.
  """

  alias Streaming.Source

  @type step_fn :: (map() -> {:ok, map()} | {:error, term()})
  @type sink_fn :: (map() -> :ok | {:error, term()})
  @type summary :: %{processed: non_neg_integer(), errors: non_neg_integer()}

  @spec run(module(), keyword(), list(step_fn()), sink_fn()) ::
          {:ok, summary()} | {:error, atom()}
  def run(source_module, source_opts, steps, sink_fn)
      when is_atom(source_module) and is_list(steps) and is_function(sink_fn, 1) do
    with {:ok, state} <- source_module.open(source_opts) do
      summary =
        state
        |> source_module.stream()
        |> Enum.reduce(%{processed: 0, errors: 0}, fn record, acc ->
          apply_steps_and_sink(record, steps, sink_fn, acc)
        end)

      source_module.close(state)
      {:ok, summary}
    end
  end

  defp apply_steps_and_sink(record, steps, sink_fn, acc) do
    result =
      Enum.reduce_while(steps, {:ok, record}, fn step_fn, {:ok, current} ->
        case step_fn.(current) do
          {:ok, transformed} -> {:cont, {:ok, transformed}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, final_record} ->
        sink_fn.(final_record)
        Map.update!(acc, :processed, &(&1 + 1))

      {:error, _} ->
        Map.update!(acc, :errors, &(&1 + 1))
    end
  end
end
```
