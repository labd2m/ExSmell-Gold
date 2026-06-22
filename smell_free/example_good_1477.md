```elixir
defmodule Pipeline.Stage do
  @moduledoc """
  Defines the behaviour that each pipeline processing stage must implement.
  """

  @callback process(batch :: [map()], config :: map()) ::
              {:ok, [map()]} | {:error, term()}
end

defmodule Pipeline.Stages.Enrich do
  @behaviour Pipeline.Stage

  @moduledoc """
  Enriches records by resolving a lookup field into a nested metadata map.
  Records missing the lookup field are passed through unchanged.
  """

  @impl Pipeline.Stage
  def process(batch, config) when is_list(batch) and is_map(config) do
    lookup_field = Map.fetch!(config, :lookup_field)
    enrichment_fn = Map.fetch!(config, :enrichment_fn)

    enriched =
      Enum.map(batch, fn record ->
        case Map.fetch(record, lookup_field) do
          {:ok, key} -> Map.put(record, :metadata, enrichment_fn.(key))
          :error -> record
        end
      end)

    {:ok, enriched}
  end
end

defmodule Pipeline.Stages.Deduplicate do
  @behaviour Pipeline.Stage

  @moduledoc """
  Removes duplicate records within a batch based on a configurable key field.
  When duplicates exist, the last occurrence is retained.
  """

  @impl Pipeline.Stage
  def process(batch, config) when is_list(batch) and is_map(config) do
    key_field = Map.fetch!(config, :key_field)

    deduped =
      batch
      |> Enum.reverse()
      |> Enum.uniq_by(&Map.get(&1, key_field))
      |> Enum.reverse()

    {:ok, deduped}
  end
end

defmodule Pipeline.Runner do
  @moduledoc """
  Executes a sequential list of named pipeline stages against a batch of records.
  Halts immediately on the first stage failure, returning the stage name and reason.
  """

  @type stage_spec :: {module(), map()}
  @type run_result :: {:ok, [map()]} | {:error, {module(), term()}}

  @spec run([map()], [stage_spec()]) :: run_result()
  def run(initial_batch, stages) when is_list(initial_batch) and is_list(stages) do
    Enum.reduce_while(stages, {:ok, initial_batch}, fn {stage_module, config}, {:ok, batch} ->
      case stage_module.process(batch, config) do
        {:ok, result} -> {:cont, {:ok, result}}
        {:error, reason} -> {:halt, {:error, {stage_module, reason}}}
      end
    end)
  end

  @spec run_parallel([map()], [stage_spec()], keyword()) :: run_result()
  def run_parallel(initial_batch, stages, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, 100)

    chunks = Enum.chunk_every(initial_batch, chunk_size)

    results =
      chunks
      |> Task.async_stream(fn chunk -> run(chunk, stages) end,
           max_concurrency: Keyword.get(opts, :concurrency, 4),
           timeout: Keyword.get(opts, :timeout, 30_000))
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, {:ok, processed}}, {:ok, acc} -> {:cont, {:ok, acc ++ processed}}
        {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
        {:exit, reason}, _acc -> {:halt, {:error, {:task_exit, reason}}}
      end)

    results
  end
end
```
