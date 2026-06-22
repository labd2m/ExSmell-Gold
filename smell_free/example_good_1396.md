**File:** `example_good_1396.md`

```elixir
defmodule ETL.Source do
  @moduledoc "Behaviour for ETL pipeline data sources."

  @doc "Opens the source and returns a stream of raw records."
  @callback stream(keyword()) :: Enumerable.t()

  @doc "Returns a human-readable name for logging."
  @callback source_name() :: String.t()
end

defmodule ETL.Transform do
  @moduledoc "Behaviour for ETL pipeline transformation steps."

  @doc """
  Transforms a single raw record. Returns `{:ok, record}` to pass it
  downstream, `{:skip, reason}` to drop it, or `{:error, reason}` to
  count it as a failure without halting the pipeline.
  """
  @callback transform(map()) :: {:ok, map()} | {:skip, term()} | {:error, term()}

  @doc "Returns a human-readable name for logging."
  @callback transform_name() :: String.t()
end

defmodule ETL.Sink do
  @moduledoc "Behaviour for ETL pipeline data sinks."

  @doc "Writes a batch of transformed records. Returns the count written."
  @callback write_batch([map()]) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc "Returns a human-readable name for logging."
  @callback sink_name() :: String.t()
end

defmodule ETL.RunStats do
  @moduledoc "Collects statistics for a completed ETL pipeline run."

  defstruct read: 0, written: 0, skipped: 0, failed: 0, duration_ms: 0

  @type t :: %__MODULE__{
          read: non_neg_integer(),
          written: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          duration_ms: non_neg_integer()
        }
end

defmodule ETL.Pipeline do
  @moduledoc """
  Executes a configurable ETL pipeline: reads from a source, applies
  a sequence of transforms, and writes to a sink in batches.
  Collects per-stage statistics throughout the run.
  """

  require Logger

  alias ETL.RunStats

  @default_batch_size 500

  @type pipeline_opts :: [
          batch_size: pos_integer(),
          source_opts: keyword()
        ]

  @spec run(module(), [module()], module(), pipeline_opts()) ::
          {:ok, RunStats.t()} | {:error, term()}
  def run(source, transforms, sink, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    source_opts = Keyword.get(opts, :source_opts, [])
    started_at = System.monotonic_time(:millisecond)

    Logger.info("ETL pipeline starting: #{source.source_name()} -> #{sink.sink_name()}")

    stats =
      source.stream(source_opts)
      |> Stream.chunk_every(batch_size)
      |> Enum.reduce(%RunStats{}, fn batch, acc ->
        process_batch(batch, transforms, sink, acc)
      end)

    duration_ms = System.monotonic_time(:millisecond) - started_at
    final_stats = %{stats | duration_ms: duration_ms}

    Logger.info(
      "ETL pipeline complete: read=#{final_stats.read} written=#{final_stats.written} " <>
        "skipped=#{final_stats.skipped} failed=#{final_stats.failed} duration=#{duration_ms}ms"
    )

    {:ok, final_stats}
  rescue
    exception ->
      Logger.error("ETL pipeline crashed: #{Exception.message(exception)}")
      {:error, Exception.message(exception)}
  end

  defp process_batch(batch, transforms, sink, %RunStats{} = stats) do
    read_count = length(batch)

    {transformed, skipped, failed} =
      Enum.reduce(batch, {[], 0, 0}, fn record, {ok, skip, fail} ->
        case apply_transforms(record, transforms) do
          {:ok, result} -> {[result | ok], skip, fail}
          {:skip, _} -> {ok, skip + 1, fail}
          {:error, reason} ->
            Logger.warning("Transform failed for record: #{inspect(reason)}")
            {ok, skip, fail + 1}
        end
      end)

    written =
      case sink.write_batch(Enum.reverse(transformed)) do
        {:ok, count} ->
          count

        {:error, reason} ->
          Logger.error("Sink write failed: #{inspect(reason)}")
          0
      end

    %RunStats{
      read: stats.read + read_count,
      written: stats.written + written,
      skipped: stats.skipped + skipped,
      failed: stats.failed + failed,
      duration_ms: stats.duration_ms
    }
  end

  defp apply_transforms(record, transforms) do
    Enum.reduce_while(transforms, {:ok, record}, fn transform, {:ok, current} ->
      case transform.transform(current) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:skip, reason} -> {:halt, {:skip, reason}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
```
