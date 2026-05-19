```elixir
defmodule DataImport.PipelineWorker do
  use GenServer

  @moduledoc """
  Executes a background data import pipeline for a single import job.
  Supports CSV and JSON sources, applies configurable transformations,
  validates rows against a schema, and writes batches to the target store.
  """

  @batch_size 100
  @progress_report_interval 500

  defstruct [
    :job_id,
    :source_type,
    :source_path,
    :target_table,
    :schema,
    :transformations,
    :status,
    :total_rows,
    :processed_rows,
    :failed_rows,
    :error_log,
    :started_at,
    :completed_at,
    :checksum
  ]

  def start(job_id, job_config) do
    state = %__MODULE__{
      job_id: job_id,
      source_type: job_config.source_type,
      source_path: job_config.source_path,
      target_table: job_config.target_table,
      schema: job_config.schema,
      transformations: Map.get(job_config, :transformations, []),
      status: :pending,
      total_rows: 0,
      processed_rows: 0,
      failed_rows: 0,
      error_log: [],
      started_at: nil,
      completed_at: nil,
      checksum: nil
    }

    GenServer.start(__MODULE__, state, name: via_name(job_id))
  end

  @doc "Starts execution of the import pipeline."
  def execute(job_id) do
    GenServer.cast(via_name(job_id), :execute)
  end

  @doc "Returns current import progress."
  def progress(job_id) do
    GenServer.call(via_name(job_id), :progress)
  end

  @doc "Cancels a running import."
  def cancel(job_id) do
    GenServer.cast(via_name(job_id), :cancel)
  end

  @doc "Returns the error log for failed rows."
  def error_log(job_id) do
    GenServer.call(via_name(job_id), :error_log)
  end

  ## Callbacks

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_cast(:execute, %{status: :pending} = state) do
    new_state = %{state | status: :running, started_at: DateTime.utc_now()}
    send(self(), :process_next_batch)
    {:noreply, new_state}
  end

  def handle_cast(:execute, state), do: {:noreply, state}

  def handle_cast(:cancel, state) do
    if state.status == :running do
      {:noreply, %{state | status: :cancelled, completed_at: DateTime.utc_now()}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:progress, _from, state) do
    pct =
      if state.total_rows > 0,
        do: Float.round(state.processed_rows / state.total_rows * 100, 1),
        else: 0.0

    progress = %{
      job_id: state.job_id,
      status: state.status,
      total_rows: state.total_rows,
      processed_rows: state.processed_rows,
      failed_rows: state.failed_rows,
      percent_complete: pct,
      started_at: state.started_at,
      completed_at: state.completed_at
    }

    {:reply, progress, state}
  end

  def handle_call(:error_log, _from, state) do
    {:reply, Enum.reverse(state.error_log), state}
  end

  @impl true
  def handle_info(:process_next_batch, %{status: :cancelled} = state) do
    {:noreply, state}
  end

  def handle_info(:process_next_batch, state) do
    case read_next_batch(state) do
      {:ok, []} ->
        final_state = %{state | status: :completed, completed_at: DateTime.utc_now()}
        persist_completion_record(final_state)
        {:noreply, final_state}

      {:ok, rows} ->
        {ok_count, fail_entries} = process_batch(rows, state)

        new_state = %{
          state
          | processed_rows: state.processed_rows + ok_count,
            failed_rows: state.failed_rows + length(fail_entries),
            error_log: Enum.take(fail_entries ++ state.error_log, 1000),
            total_rows: state.total_rows + length(rows)
        }

        if rem(new_state.processed_rows, @progress_report_interval) == 0 do
          emit_progress_event(new_state)
        end

        send(self(), :process_next_batch)
        {:noreply, new_state}

      {:error, reason} ->
        {:noreply, %{state | status: :failed, completed_at: DateTime.utc_now(),
                             error_log: [{:source_read_error, reason} | state.error_log]}}
    end
  end

  defp process_batch(rows, state) do
    Enum.reduce(rows, {0, []}, fn row, {ok_count, errors} ->
      with {:ok, transformed} <- apply_transformations(row, state.transformations),
           :ok <- validate_row(transformed, state.schema),
           :ok <- write_row(transformed, state.target_table) do
        {ok_count + 1, errors}
      else
        {:error, reason} ->
          {ok_count, [{row, reason} | errors]}
      end
    end)
  end

  defp apply_transformations(row, []), do: {:ok, row}

  defp apply_transformations(row, [transform | rest]) do
    case apply_transform(row, transform) do
      {:ok, new_row} -> apply_transformations(new_row, rest)
      error -> error
    end
  end

  defp apply_transform(row, %{type: :rename, from: from, to: to}) do
    if Map.has_key?(row, from) do
      {:ok, row |> Map.delete(from) |> Map.put(to, Map.get(row, from))}
    else
      {:ok, row}
    end
  end

  defp apply_transform(row, %{type: :cast, field: field, as: :integer}) do
    case Map.fetch(row, field) do
      {:ok, val} ->
        case Integer.parse(to_string(val)) do
          {int, ""} -> {:ok, Map.put(row, field, int)}
          _ -> {:error, {:cast_failed, field, val}}
        end

      :error ->
        {:ok, row}
    end
  end

  defp apply_transform(row, _unknown), do: {:ok, row}

  defp validate_row(_row, _schema), do: :ok
  defp write_row(_row, _table), do: :ok
  defp read_next_batch(_state), do: {:ok, []}
  defp persist_completion_record(_state), do: :ok
  defp emit_progress_event(_state), do: :ok

  defp via_name(job_id) do
    {:via, Registry, {DataImport.JobRegistry, job_id}}
  end
end
```
