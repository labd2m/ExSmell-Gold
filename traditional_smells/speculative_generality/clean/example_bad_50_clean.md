```elixir
defmodule Scheduling.TaskScheduler do
  @moduledoc """
  Schedules and manages background tasks for deferred and recurring execution.
  Supports one-off enqueue, recurring scheduling, cancellation, and status queries.
  """

  alias Scheduling.{TaskSpec, TaskRecord, TaskQueue, WorkerRegistry}

  @default_queue         :default
  @max_attempts          3
  @retry_backoff_seconds 60

  def enqueue(%TaskSpec{} = spec, opts \\ []) do
    run_at = Keyword.get(opts, :run_at, DateTime.utc_now())
    queue  = Keyword.get(opts, :queue, @default_queue)

    with :ok            <- validate_spec(spec),
         {:ok, record}  <- persist_task(spec, run_at, queue) do
      {:ok, record}
    end
  end

  def process_due(queue \\ @default_queue) do
    queue
    |> TaskQueue.pop_due(DateTime.utc_now())
    |> Enum.each(&dispatch_task/1)
  end

  def cancel(task_id) do
    case TaskRecord.fetch(task_id) do
      {:ok, %TaskRecord{status: :pending} = record} ->
        TaskRecord.update(record, %{status: :cancelled, cancelled_at: DateTime.utc_now()})

      {:ok, %TaskRecord{status: status}} ->
        {:error, {:cannot_cancel, status}}

      {:error, :not_found} ->
        {:error, :task_not_found}
    end
  end

  def reschedule(task_id, new_run_at) do
    with {:ok, record} <- TaskRecord.fetch(task_id),
         true          <- record.status in [:pending, :failed] do
      TaskRecord.update(record, %{run_at: new_run_at, status: :pending})
    else
      false -> {:error, :not_reschedulable}
      error -> error
    end
  end

  def status(task_id) do
    case TaskRecord.fetch(task_id) do
      {:ok, record} ->
        {:ok,
         %{
           id:         record.id,
           type:       record.type,
           status:     record.status,
           run_at:     record.run_at,
           attempts:   record.attempts,
           last_error: record.last_error
         }}

      {:error, :not_found} ->
        {:error, :task_not_found}
    end
  end

  def list_pending(queue \\ @default_queue) do
    TaskQueue.list_pending(queue)
  end

  def schedule_recurring(%TaskSpec{} = spec, interval_seconds, priority \\ :normal) do
    next_run = DateTime.add(DateTime.utc_now(), interval_seconds)

    record = %TaskRecord{
      type:        spec.type,
      payload:     spec.payload,
      priority:    priority,
      queue:       @default_queue,
      run_at:      next_run,
      interval:    interval_seconds,
      status:      :pending,
      attempts:    0,
      max_attempts: @max_attempts,
      created_at:  DateTime.utc_now()
    }

    TaskQueue.insert(record)
  end
  

  defp validate_spec(%TaskSpec{type: type, payload: payload}) do
    cond do
      is_nil(type)    -> {:error, :missing_task_type}
      is_nil(payload) -> {:error, :missing_payload}
      true            -> :ok
    end
  end

  defp persist_task(%TaskSpec{} = spec, run_at, queue) do
    record = %TaskRecord{
      type:         spec.type,
      payload:      spec.payload,
      queue:        queue,
      run_at:       run_at,
      status:       :pending,
      attempts:     0,
      max_attempts: @max_attempts,
      created_at:   DateTime.utc_now()
    }

    TaskRecord.insert(record)
  end

  defp dispatch_task(%TaskRecord{} = record) do
    case WorkerRegistry.find_worker(record.type) do
      {:ok, worker_mod} ->
        Task.start(fn ->
          case worker_mod.perform(record.payload) do
            :ok ->
              TaskRecord.update(record, %{
                status:       :completed,
                completed_at: DateTime.utc_now()
              })

            {:error, reason} ->
              attempts = record.attempts + 1
              status   = if attempts >= @max_attempts, do: :dead, else: :failed
              retry_at = DateTime.add(DateTime.utc_now(), @retry_backoff_seconds * attempts)

              TaskRecord.update(record, %{
                status:     status,
                attempts:   attempts,
                last_error: inspect(reason),
                run_at:     retry_at
              })
          end
        end)

      {:error, :no_worker} ->
        TaskRecord.update(record, %{
          status:     :dead,
          last_error: "no worker registered for type: #{record.type}"
        })
    end
  end
end
```
