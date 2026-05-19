# Code Smell: Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `PipelineWorker.start/2`
- **Affected function(s):** `PipelineWorker.start/2`, `PipelineOrchestrator.run/2`
- **Short explanation:** Each ETL pipeline stage is executed by its own `GenServer` spawned with `GenServer.start/3`. Because these workers are not supervised, a crash in any stage silently drops data and leaves the orchestrator with a stale view of pipeline progress.

```elixir
defmodule PipelineWorker do
  use GenServer

  @moduledoc """
  Executes a single stage in a data transformation pipeline.
  Reads from an upstream source, applies transformations, and writes results downstream.
  """

  defstruct [
    :pipeline_id,
    :stage_name,
    :transform_fn,
    :upstream,
    :downstream,
    :status,
    rows_processed: 0,
    rows_failed: 0,
    errors: []
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because each pipeline stage is a stateful,
  # long-running `GenServer` started via `GenServer.start/3` outside any
  # supervision tree. ETL pipelines may run for extended periods; a crash
  # at any stage interrupts the data flow silently, and the orchestrator
  # continues unaware that data is no longer being processed.
  def start(pipeline_id, stage_spec) do
    GenServer.start(
      __MODULE__,
      Map.put(stage_spec, :pipeline_id, pipeline_id),
      name: via(pipeline_id, stage_spec.stage_name)
    )
  end
  # VALIDATION: SMELL END

  def run(pipeline_id, stage_name) do
    GenServer.call(via(pipeline_id, stage_name), :run, 120_000)
  end

  def stats(pipeline_id, stage_name) do
    GenServer.call(via(pipeline_id, stage_name), :stats)
  end

  def stop_worker(pipeline_id, stage_name) do
    GenServer.stop(via(pipeline_id, stage_name))
  end

  defp via(pipeline_id, stage_name) do
    {:via, Registry, {PipelineRegistry, {pipeline_id, stage_name}}}
  end

  ## Callbacks

  @impl true
  def init(%{pipeline_id: pid, stage_name: name, transform_fn: tfn, upstream: up, downstream: dn}) do
    state = %__MODULE__{
      pipeline_id: pid,
      stage_name: name,
      transform_fn: tfn,
      upstream: up,
      downstream: dn,
      status: :ready
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:run, _from, %{status: :ready} = state) do
    state = %{state | status: :running}

    {processed, failed, errors, final_state} = process_upstream(state)

    done_state = %{final_state |
      status: :done,
      rows_processed: processed,
      rows_failed: failed,
      errors: errors
    }

    {:reply, {:ok, %{processed: processed, failed: failed}}, done_state}
  end

  def handle_call(:run, _from, state) do
    {:reply, {:error, {:invalid_status, state.status}}, state}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      stage: state.stage_name,
      status: state.status,
      rows_processed: state.rows_processed,
      rows_failed: state.rows_failed,
      error_count: length(state.errors)
    }

    {:reply, stats, state}
  end

  defp process_upstream(state) do
    rows = fetch_rows(state.upstream)

    {ok, err, errors} =
      Enum.reduce(rows, {0, 0, []}, fn row, {ok, err, errs} ->
        case apply_transform(state.transform_fn, row) do
          {:ok, transformed} ->
            write_downstream(state.downstream, transformed)
            {ok + 1, err, errs}

          {:error, reason} ->
            {ok, err + 1, [{row, reason} | errs]}
        end
      end)

    {ok, err, errors, state}
  end

  defp fetch_rows(:memory_source), do: Enum.map(1..100, &%{id: &1, value: &1 * 2})
  defp fetch_rows(_), do: []

  defp apply_transform(fun, row) when is_function(fun), do: fun.(row)
  defp apply_transform(:identity, row), do: {:ok, row}
  defp apply_transform(:double, %{value: v} = row), do: {:ok, %{row | value: v * 2}}

  defp write_downstream(:sink, _row), do: :ok
  defp write_downstream(_, _), do: :ok
end

defmodule PipelineOrchestrator do
  @moduledoc "Builds and executes a multi-stage data pipeline."

  def run(pipeline_id, stages) do
    Enum.each(stages, fn stage ->
      {:ok, _pid} = PipelineWorker.start(pipeline_id, stage)
    end)

    results =
      Enum.map(stages, fn stage ->
        {stage.stage_name, PipelineWorker.run(pipeline_id, stage.stage_name)}
      end)

    Enum.each(stages, fn stage ->
      PipelineWorker.stop_worker(pipeline_id, stage.stage_name)
    end)

    {:ok, results}
  end
end
```
