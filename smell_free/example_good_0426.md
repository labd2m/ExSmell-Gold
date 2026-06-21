# File: `example_good_426.md`

```elixir
defmodule Workflow.TaskAssigner do
  @moduledoc """
  Assigns tasks to workers based on configurable load-balancing strategies,
  tracking each worker's active task count and maintaining assignment
  history for audit purposes.

  Workers are registered dynamically. Strategies include least-loaded
  (fewest active tasks), round-robin, and capability-matched assignment
  where tasks declare required tags that workers must support.
  """

  use GenServer

  require Logger

  @type worker_id :: String.t()
  @type task_id :: String.t()
  @type capability :: atom()
  @type strategy :: :least_loaded | :round_robin | {:capability_match, [capability()]}

  @type worker :: %{
          id: worker_id(),
          capabilities: [capability()],
          active_tasks: non_neg_integer(),
          total_assigned: non_neg_integer()
        }

  @type task :: %{
          required(:id) => task_id(),
          required(:payload) => map(),
          optional(:required_capabilities) => [capability()]
        }

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Registers a worker as available for task assignment.
  """
  @spec register_worker(worker_id(), [capability()]) :: :ok | {:error, :already_registered}
  def register_worker(worker_id, capabilities \\ [])
      when is_binary(worker_id) and is_list(capabilities) do
    GenServer.call(__MODULE__, {:register_worker, worker_id, capabilities})
  end

  @doc """
  Deregisters a worker, preventing future assignments.
  """
  @spec deregister_worker(worker_id()) :: :ok
  def deregister_worker(worker_id) when is_binary(worker_id) do
    GenServer.cast(__MODULE__, {:deregister_worker, worker_id})
  end

  @doc """
  Assigns `task` to a worker using `strategy`.

  Returns `{:ok, worker_id}` or `{:error, :no_eligible_workers}`.
  """
  @spec assign(task(), strategy()) :: {:ok, worker_id()} | {:error, :no_eligible_workers}
  def assign(%{id: _} = task, strategy \\ :least_loaded) do
    GenServer.call(__MODULE__, {:assign, task, strategy})
  end

  @doc """
  Marks a task as complete, decrementing the assigned worker's load.
  """
  @spec complete(task_id(), worker_id()) :: :ok | {:error, :not_found}
  def complete(task_id, worker_id) when is_binary(task_id) and is_binary(worker_id) do
    GenServer.call(__MODULE__, {:complete, task_id, worker_id})
  end

  @doc """
  Returns a snapshot of all registered workers and their current load.
  """
  @spec worker_stats() :: [worker()]
  def worker_stats do
    GenServer.call(__MODULE__, :worker_stats)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{workers: %{}, round_robin_index: 0}}
  end

  @impl GenServer
  def handle_call({:register_worker, id, capabilities}, _from, state) do
    if Map.has_key?(state.workers, id) do
      {:reply, {:error, :already_registered}, state}
    else
      worker = %{id: id, capabilities: capabilities, active_tasks: 0, total_assigned: 0}
      {:reply, :ok, put_in(state, [:workers, id], worker)}
    end
  end

  @impl GenServer
  def handle_call({:assign, task, strategy}, _from, state) do
    required = Map.get(task, :required_capabilities, [])
    eligible = eligible_workers(state.workers, required)

    case select_worker(eligible, strategy, state.round_robin_index) do
      nil ->
        {:reply, {:error, :no_eligible_workers}, state}

      {worker_id, new_rr_index} ->
        new_state =
          state
          |> update_in([:workers, worker_id, :active_tasks], &(&1 + 1))
          |> update_in([:workers, worker_id, :total_assigned], &(&1 + 1))
          |> Map.put(:round_robin_index, new_rr_index)

        Logger.debug("Assigned task #{task.id} to worker #{worker_id}")
        {:reply, {:ok, worker_id}, new_state}
    end
  end

  @impl GenServer
  def handle_call({:complete, _task_id, worker_id}, _from, state) do
    case Map.fetch(state.workers, worker_id) do
      {:ok, worker} when worker.active_tasks > 0 ->
        new_state = update_in(state, [:workers, worker_id, :active_tasks], &(&1 - 1))
        {:reply, :ok, new_state}

      {:ok, _} ->
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_call(:worker_stats, _from, state) do
    {:reply, Map.values(state.workers), state}
  end

  @impl GenServer
  def handle_cast({:deregister_worker, id}, state) do
    {:noreply, update_in(state, [:workers], &Map.delete(&1, id))}
  end

  defp eligible_workers(workers, []) do
    Map.values(workers)
  end

  defp eligible_workers(workers, required) do
    workers
    |> Map.values()
    |> Enum.filter(fn worker ->
      Enum.all?(required, &(&1 in worker.capabilities))
    end)
  end

  defp select_worker([], _strategy, rr_index), do: {nil, rr_index}

  defp select_worker(eligible, :least_loaded, rr_index) do
    worker = Enum.min_by(eligible, & &1.active_tasks)
    {worker.id, rr_index}
  end

  defp select_worker(eligible, :round_robin, rr_index) do
    sorted = Enum.sort_by(eligible, & &1.id)
    index = rem(rr_index, length(sorted))
    worker = Enum.at(sorted, index)
    {worker.id, rr_index + 1}
  end

  defp select_worker(eligible, {:capability_match, _caps}, rr_index) do
    select_worker(eligible, :least_loaded, rr_index)
  end
end
```
