```elixir
defmodule Tasks.BackgroundQueue do
  @moduledoc """
  Supervised task queue that executes short-lived background jobs
  with a configurable concurrency limit.

  Jobs are submitted as `{module, function, args}` tuples and executed
  under a `Task.Supervisor`, ensuring that failures do not propagate
  to the caller and that all tasks are properly supervised.
  """

  use GenServer

  alias Tasks.JobResult

  @type mfa_job :: {module(), atom(), list()}
  @type queue_state :: %{
          pending: :queue.queue(),
          active_count: non_neg_integer(),
          max_concurrency: pos_integer(),
          results: [JobResult.t()]
        }

  @default_max_concurrency 5

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Enqueues an MFA job for background execution.
  """
  @spec enqueue(mfa_job()) :: :ok
  def enqueue({mod, fun, args} = job)
      when is_atom(mod) and is_atom(fun) and is_list(args) do
    GenServer.cast(__MODULE__, {:enqueue, job})
  end

  @doc """
  Returns the current number of actively running jobs.
  """
  @spec active_count() :: non_neg_integer()
  def active_count do
    GenServer.call(__MODULE__, :active_count)
  end

  @doc """
  Returns a list of completed job results since last reset.
  """
  @spec completed_results() :: [JobResult.t()]
  def completed_results do
    GenServer.call(__MODULE__, :completed_results)
  end

  @impl GenServer
  def init(opts) do
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)

    state = %{
      pending: :queue.new(),
      active_count: 0,
      max_concurrency: max_concurrency,
      results: []
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:enqueue, job}, state) do
    updated_queue = :queue.in(job, state.pending)
    new_state = %{state | pending: updated_queue}
    {:noreply, drain(new_state)}
  end

  @impl GenServer
  def handle_call(:active_count, _from, state) do
    {:reply, state.active_count, state}
  end

  def handle_call(:completed_results, _from, state) do
    {:reply, state.results, state}
  end

  @impl GenServer
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    job_result = JobResult.new(:ok, result)

    new_state =
      state
      |> Map.update!(:active_count, &(&1 - 1))
      |> Map.update!(:results, &[job_result | &1])

    {:noreply, drain(new_state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) when reason != :normal do
    job_result = JobResult.new(:error, reason)

    new_state =
      state
      |> Map.update!(:active_count, &max(0, &1 - 1))
      |> Map.update!(:results, &[job_result | &1])

    {:noreply, drain(new_state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    {:noreply, drain(%{state | active_count: max(0, state.active_count - 1)})}
  end

  @spec drain(queue_state()) :: queue_state()
  defp drain(%{active_count: active, max_concurrency: max} = state)
       when active >= max do
    state
  end

  defp drain(%{pending: queue} = state) do
    case :queue.out(queue) do
      {:empty, _} ->
        state

      {{:value, {mod, fun, args}}, rest} ->
        %{ref: _ref} = Task.Supervisor.async_nolink(Tasks.Supervisor, mod, fun, args)

        state
        |> Map.put(:pending, rest)
        |> Map.update!(:active_count, &(&1 + 1))
        |> drain()
    end
  end
end
```
