```elixir
defmodule Infra.Workers.DynamicPool do
  @moduledoc """
  Supervised dynamic worker pool with runtime scaling support.

  Manages a bounded set of stateless workers, distributing work
  via round-robin dispatch and supporting live pool size adjustments
  without restarting the supervisor.
  """

  use Supervisor

  alias Infra.Workers.DynamicPool.{Worker, DispatchRouter}

  @type pool_config :: %{
          name: atom(),
          min_workers: pos_integer(),
          max_workers: pos_integer(),
          worker_module: module()
        }

  @doc """
  Starts the pool supervisor with the given configuration.
  """
  @spec start_link(pool_config()) :: Supervisor.on_start()
  def start_link(%{name: name} = config) do
    Supervisor.start_link(__MODULE__, config, name: supervisor_name(name))
  end

  @impl Supervisor
  def init(%{name: name, min_workers: min, worker_module: mod}) do
    router_child = {DispatchRouter, pool_name: name}

    worker_children =
      for index <- 1..min do
        Supervisor.child_spec(
          {Worker, pool_name: name, index: index, module: mod},
          id: {Worker, index}
        )
      end

    Supervisor.init([router_child | worker_children], strategy: :one_for_one)
  end

  @doc """
  Dispatches a job to the next available worker in the pool.

  Returns `{:ok, result}` or `{:error, :no_workers_available}`.
  """
  @spec dispatch(atom(), term()) :: {:ok, term()} | {:error, :no_workers_available}
  def dispatch(pool_name, job) do
    case DispatchRouter.next_worker(pool_name) do
      {:ok, worker_pid} -> Worker.execute(worker_pid, job)
      {:error, :empty_pool} -> {:error, :no_workers_available}
    end
  end

  @doc """
  Scales the pool up by adding the given number of additional workers.

  Respects the configured `max_workers` ceiling.
  """
  @spec scale_up(atom(), pos_integer(), module()) :: {:ok, pos_integer()} | {:error, :at_max_capacity}
  def scale_up(pool_name, count, worker_module) do
    sup = supervisor_name(pool_name)
    current = current_worker_count(sup)
    max = DispatchRouter.max_workers(pool_name)

    if current >= max do
      {:error, :at_max_capacity}
    else
      to_add = min(count, max - current)

      for i <- 1..to_add do
        index = current + i
        spec = Supervisor.child_spec(
          {Worker, pool_name: pool_name, index: index, module: worker_module},
          id: {Worker, index}
        )
        Supervisor.start_child(sup, spec)
      end

      {:ok, current + to_add}
    end
  end

  @doc """
  Scales the pool down by terminating the given number of workers.

  Respects the configured `min_workers` floor.
  """
  @spec scale_down(atom(), pos_integer()) :: {:ok, pos_integer()} | {:error, :at_min_capacity}
  def scale_down(pool_name, count) do
    sup = supervisor_name(pool_name)
    current = current_worker_count(sup)
    min = DispatchRouter.min_workers(pool_name)

    if current <= min do
      {:error, :at_min_capacity}
    else
      to_remove = min(count, current - min)
      remove_workers(sup, current, to_remove)
      {:ok, current - to_remove}
    end
  end

  defp remove_workers(sup, current_count, to_remove) do
    for i <- 0..(to_remove - 1) do
      index = current_count - i
      Supervisor.terminate_child(sup, {Worker, index})
      Supervisor.delete_child(sup, {Worker, index})
    end
  end

  defp current_worker_count(sup) do
    sup
    |> Supervisor.which_children()
    |> Enum.count(fn {id, _, _, _} -> match?({Worker, _}, id) end)
  end

  defp supervisor_name(pool_name), do: :"#{pool_name}.Supervisor"
end
```
