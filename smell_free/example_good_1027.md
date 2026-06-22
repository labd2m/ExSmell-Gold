```elixir
defmodule Infra.BackgroundJobRunner do
  @moduledoc """
  Executes named background jobs defined as modules implementing the
  `Infra.BackgroundJob` behaviour. Jobs are dispatched to a supervised
  task pool and their outcomes logged with telemetry. Each run is
  assigned a unique execution ID so concurrent runs of the same job
  can be correlated in structured logs.
  """

  require Logger

  @type job_module :: module()
  @type exec_id :: String.t()
  @type run_result :: {:ok, exec_id()} | {:error, exec_id(), term()}

  @telemetry_start [:infra, :background_job, :start]
  @telemetry_stop  [:infra, :background_job, :stop]

  @doc """
  Dispatches `job_module` to the task supervisor. Returns the execution ID
  immediately; the job runs asynchronously.
  """
  @spec dispatch(job_module(), map()) :: {:ok, exec_id()}
  def dispatch(job_module, params \\ %{}) when is_atom(job_module) and is_map(params) do
    exec_id = generate_exec_id()
    supervisor = job_supervisor()

    Task.Supervisor.start_child(supervisor, fn ->
      run(job_module, params, exec_id)
    end)

    {:ok, exec_id}
  end

  @doc """
  Runs `job_module` synchronously and returns the result. Useful for
  scheduled jobs where the caller needs to know the outcome.
  """
  @spec run_sync(job_module(), map()) :: run_result()
  def run_sync(job_module, params \\ %{}) when is_atom(job_module) and is_map(params) do
    exec_id = generate_exec_id()
    run(job_module, params, exec_id)
  end

  defp run(job_module, params, exec_id) do
    start_time = System.monotonic_time()

    :telemetry.execute(@telemetry_start, %{system_time: System.system_time()}, %{
      job: job_module,
      exec_id: exec_id
    })

    Logger.info("[BackgroundJobRunner] Starting #{inspect(job_module)} exec_id=#{exec_id}")

    result =
      try do
        job_module.perform(params)
      rescue
        e -> {:error, Exception.message(e)}
      end

    duration = System.monotonic_time() - start_time
    ms = System.convert_time_unit(duration, :native, :millisecond)

    case result do
      :ok ->
        :telemetry.execute(@telemetry_stop, %{duration: duration}, %{job: job_module, exec_id: exec_id, status: :ok})
        Logger.info("[BackgroundJobRunner] Completed #{inspect(job_module)} exec_id=#{exec_id} #{ms}ms")
        {:ok, exec_id}

      {:ok, _} ->
        :telemetry.execute(@telemetry_stop, %{duration: duration}, %{job: job_module, exec_id: exec_id, status: :ok})
        Logger.info("[BackgroundJobRunner] Completed #{inspect(job_module)} exec_id=#{exec_id} #{ms}ms")
        {:ok, exec_id}

      {:error, reason} ->
        :telemetry.execute(@telemetry_stop, %{duration: duration}, %{job: job_module, exec_id: exec_id, status: :error})
        Logger.error("[BackgroundJobRunner] Failed #{inspect(job_module)} exec_id=#{exec_id}: #{inspect(reason)}")
        {:error, exec_id, reason}
    end
  end

  defp generate_exec_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp job_supervisor do
    Application.get_env(:my_app, :background_job_supervisor, MyApp.TaskSupervisor)
  end
end

defmodule Infra.BackgroundJob do
  @moduledoc "Behaviour for background job modules."
  @callback perform(params :: map()) :: :ok | {:ok, term()} | {:error, term()}
end
```
