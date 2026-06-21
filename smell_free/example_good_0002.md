# File: `example_good_02.md`

```elixir
defmodule DataPipeline.BatchWorker do
  @moduledoc """
  A supervised GenServer that processes a fixed batch of records
  and reports results to a configurable sink module upon completion.

  Workers are started with `:temporary` restart semantics and are
  expected to terminate normally after exhausting their batch.
  """

  use GenServer, restart: :temporary

  alias DataPipeline.RecordTransformer

  @type start_opts :: [
          batch_id: String.t(),
          records: [map()],
          sink: module()
        ]

  @type state :: %{
          batch_id: String.t(),
          records: [map()],
          sink: module(),
          processed: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc false
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Returns the batch ID currently assigned to this worker.

  Returns `{:ok, batch_id}` or `{:error, :stopped}` if the process
  has already terminated.
  """
  @spec current_batch_id(pid()) :: {:ok, String.t()} | {:error, :stopped}
  def current_batch_id(pid) when is_pid(pid) do
    try do
      {:ok, GenServer.call(pid, :current_batch_id)}
    catch
      :exit, _ -> {:error, :stopped}
    end
  end

  @doc """
  Returns a progress snapshot for the worker's current processing state.

  Returns `{:ok, progress_map}` or `{:error, :stopped}`.
  """
  @spec progress(pid()) :: {:ok, map()} | {:error, :stopped}
  def progress(pid) when is_pid(pid) do
    try do
      {:ok, GenServer.call(pid, :progress)}
    catch
      :exit, _ -> {:error, :stopped}
    end
  end

  @impl GenServer
  def init(opts) do
    state = %{
      batch_id: Keyword.fetch!(opts, :batch_id),
      records: Keyword.fetch!(opts, :records),
      sink: Keyword.fetch!(opts, :sink),
      processed: 0,
      failed: 0
    }

    {:ok, state, {:continue, :process_batch}}
  end

  @impl GenServer
  def handle_continue(:process_batch, state) do
    {processed, failed} = run_batch(state.records, state.sink)

    state.sink.on_complete(state.batch_id, %{processed: processed, failed: failed})

    {:stop, :normal, %{state | processed: processed, failed: failed}}
  end

  @impl GenServer
  def handle_call(:current_batch_id, _from, state) do
    {:reply, state.batch_id, state}
  end

  @impl GenServer
  def handle_call(:progress, _from, state) do
    snapshot = %{
      batch_id: state.batch_id,
      total: length(state.records),
      processed: state.processed,
      failed: state.failed
    }

    {:reply, snapshot, state}
  end

  defp run_batch(records, sink) do
    Enum.reduce(records, {0, 0}, fn record, {ok_count, err_count} ->
      record
      |> RecordTransformer.transform()
      |> dispatch_to_sink(sink, ok_count, err_count)
    end)
  end

  defp dispatch_to_sink({:ok, transformed}, sink, ok_count, err_count) do
    case sink.ingest(transformed) do
      :ok -> {ok_count + 1, err_count}
      {:error, _reason} -> {ok_count, err_count + 1}
    end
  end

  defp dispatch_to_sink({:error, _reason}, _sink, ok_count, err_count) do
    {ok_count, err_count + 1}
  end
end
```
