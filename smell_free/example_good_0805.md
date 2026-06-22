```elixir
defmodule MyApp.Infra.AsyncTaskRunner do
  @moduledoc """
  A supervised wrapper around `Task.Supervisor` that provides structured
  fire-and-forget execution with automatic error reporting. Tasks are
  named, time-limited, and their outcomes are emitted via telemetry so
  that dashboards and alerting systems can track success rates without
  coupling each call-site to observability infrastructure.
  """

  require Logger

  @supervisor MyApp.Tasks.TaskSupervisor
  @default_timeout_ms 30_000

  @type task_name :: String.t()
  @type task_fn :: (-> :ok | {:ok, term()} | {:error, term()})

  @doc """
  Runs `fun` asynchronously under the task supervisor. Returns `{:ok, pid}`
  immediately. The task's outcome is logged and emitted via telemetry when
  it completes. Raises if the supervisor is not running.
  """
  @spec run_async(task_name(), task_fn()) :: {:ok, pid()}
  def run_async(task_name, fun) when is_binary(task_name) and is_function(fun, 0) do
    {:ok, pid} =
      Task.Supervisor.start_child(@supervisor, fn ->
        run_with_instrumentation(task_name, fun)
      end)

    {:ok, pid}
  end

  @doc """
  Runs `fun` synchronously with a timeout. Returns the function result or
  `{:error, :timeout}` if it does not complete within `timeout_ms`.
  """
  @spec run_sync(task_name(), task_fn(), pos_integer()) ::
          :ok | {:ok, term()} | {:error, term()} | {:error, :timeout}
  def run_sync(task_name, fun, timeout_ms \\ @default_timeout_ms)
      when is_binary(task_name) and is_function(fun, 0) do
    task = Task.Supervisor.async_nolink(@supervisor, fn ->
      run_with_instrumentation(task_name, fun)
    end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  @doc """
  Runs all tasks in `fns` concurrently with a shared timeout. Returns
  results in the same order as inputs; timed-out tasks return
  `{:error, :timeout}`.
  """
  @spec run_all(task_name(), [task_fn()], pos_integer()) ::
          [:ok | {:ok, term()} | {:error, term()}]
  def run_all(task_name, fns, timeout_ms \\ @default_timeout_ms)
      when is_binary(task_name) and is_list(fns) do
    fns
    |> Enum.with_index(1)
    |> Task.async_stream(
      fn {fun, idx} ->
        run_with_instrumentation("#{task_name}.#{idx}", fun)
      end,
      timeout: timeout_ms,
      on_timeout: :kill_task,
      supervisor: @supervisor
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, _} -> {:error, :timeout}
    end)
  end

  @spec run_with_instrumentation(task_name(), task_fn()) ::
          :ok | {:ok, term()} | {:error, term()}
  defp run_with_instrumentation(task_name, fun) do
    start_ms = System.monotonic_time(:millisecond)

    result =
      try do
        fun.()
      rescue
        e ->
          Logger.error("async_task_exception", task: task_name, error: Exception.message(e))
          {:error, {:exception, Exception.message(e)}}
      end

    duration_ms = System.monotonic_time(:millisecond) - start_ms
    outcome = if match?({:error, _}, result), do: :error, else: :ok

    :telemetry.execute(
      [:my_app, :async_task, :complete],
      %{duration_ms: duration_ms},
      %{task: task_name, outcome: outcome}
    )

    result
  end
end
```
