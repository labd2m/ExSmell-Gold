```elixir
defmodule MyApp.ReportWorkerTask do
  @moduledoc """
  Generates and caches financial and operational reports on demand.
  Processes queued report requests and tracks generation progress.
  """

  alias MyApp.{ReportRenderer, StorageService, AuditLog}
  alias MyApp.Reports.{ReportJob, ReportResult}

  @max_queue_size 50

  def start_worker(config) do
    Task.start_link(fn ->
      state = %{
        config: config,
        queue: :queue.new(),
        in_progress: nil,
        results: %{},
        completed: 0,
        failed: 0
      }

      worker_loop(state)
    end)
  end

  defp worker_loop(state) do
    receive do
      {:enqueue, from, %ReportJob{} = job} ->
        if :queue.len(state.queue) >= @max_queue_size do
          send(from, {:error, :queue_full})
          worker_loop(state)
        else
          new_queue = :queue.in(job, state.queue)
          send(from, {:ok, job.id})
          new_state = maybe_process_next(%{state | queue: new_queue})
          worker_loop(new_state)
        end

      {:job_done, result_or_error} ->
        new_state =
          case result_or_error do
            {:ok, result} ->
              %{
                state
                | in_progress: nil,
                  results: Map.put(state.results, result.job_id, result),
                  completed: state.completed + 1
              }

            {:error, job_id, reason} ->
              AuditLog.record(:report_failed, %{job_id: job_id, reason: reason})
              %{state | in_progress: nil, failed: state.failed + 1}
          end

        worker_loop(maybe_process_next(new_state))

      {:get_result, from, job_id} ->
        case Map.fetch(state.results, job_id) do
          {:ok, result} -> send(from, {:ok, result})
          :error -> send(from, {:error, :not_found})
        end

        worker_loop(state)

      {:get_status, from} ->
        status = %{
          queue_length: :queue.len(state.queue),
          in_progress: state.in_progress && state.in_progress.id,
          completed: state.completed,
          failed: state.failed,
          cached_results: map_size(state.results)
        }
        send(from, {:ok, status})
        worker_loop(state)

      {:cancel, from, job_id} ->
        filtered = :queue.filter(fn j -> j.id != job_id end, state.queue)
        send(from, :ok)
        worker_loop(%{state | queue: filtered})

      :stop ->
        :ok
    end
  end


  defp maybe_process_next(%{in_progress: nil} = state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, job}, rest} ->
        worker_self = self()

        Task.start(fn ->
          result =
            case ReportRenderer.generate(job) do
              {:ok, data} ->
                report = %ReportResult{
                  job_id: job.id,
                  data: data,
                  format: job.format,
                  generated_at: DateTime.utc_now()
                }

                case StorageService.store(report) do
                  {:ok, _} -> {:ok, report}
                  {:error, r} -> {:error, job.id, r}
                end

              {:error, reason} ->
                {:error, job.id, reason}
            end

          send(worker_self, {:job_done, result})
        end)

        %{state | queue: rest, in_progress: job}
    end
  end

  defp maybe_process_next(state), do: state

  def enqueue(pid, job) do
    send(pid, {:enqueue, self(), job})

    receive do
      {:ok, id} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    after
      5_000 -> {:error, :timeout}
    end
  end

  def get_result(pid, job_id) do
    send(pid, {:get_result, self(), job_id})

    receive do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    after
      5_000 -> {:error, :timeout}
    end
  end
end
```
