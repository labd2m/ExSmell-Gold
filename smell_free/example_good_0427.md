# File: `example_good_427.md`

```elixir
defmodule DataPipeline.PartitionRouter do
  @moduledoc """
  Routes incoming messages to a fixed set of partition workers based on
  a partition key, ensuring all messages with the same key are processed
  by the same worker (ordered processing per key).

  Each partition is backed by a supervised worker process. The router
  computes the target partition via consistent hashing on the key and
  dispatches without buffering in the router itself.
  """

  use GenServer

  alias DataPipeline.PartitionWorker

  @type partition_key :: String.t()
  @type message :: map()
  @type partition_index :: non_neg_integer()

  @type opts :: [
          partition_count: pos_integer(),
          worker_module: module()
        ]

  @doc false
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Routes `message` to the partition responsible for `key`.

  The same key always maps to the same partition, preserving ordering
  within a key's message stream.

  Returns `:ok` immediately; delivery to the partition worker is async.
  """
  @spec route(partition_key(), message()) :: :ok | {:error, :no_partitions}
  def route(key, message) when is_binary(key) and is_map(message) do
    GenServer.call(__MODULE__, {:route, key, message})
  end

  @doc """
  Returns the partition index that would be assigned to `key`.
  """
  @spec partition_for(partition_key()) :: {:ok, partition_index()} | {:error, :no_partitions}
  def partition_for(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:partition_for, key})
  end

  @doc """
  Returns statistics for each partition: message count and current
  queue depth (if supported by the worker module).
  """
  @spec partition_stats() :: [%{partition: partition_index(), pid: pid(), message_count: non_neg_integer()}]
  def partition_stats do
    GenServer.call(__MODULE__, :partition_stats)
  end

  @doc """
  Rebalances the partition set to a new count, restarting workers as needed.

  Note: in-flight messages are not redistributed; this should be performed
  during a low-traffic window.
  """
  @spec resize(pos_integer()) :: :ok
  def resize(new_count) when is_integer(new_count) and new_count > 0 do
    GenServer.call(__MODULE__, {:resize, new_count})
  end

  @impl GenServer
  def init(opts) do
    partition_count = Keyword.get(opts, :partition_count, 8)
    worker_module = Keyword.get(opts, :worker_module, PartitionWorker)

    partitions = start_partitions(partition_count, worker_module)

    {:ok, %{partitions: partitions, worker_module: worker_module, message_counts: %{}}}
  end

  @impl GenServer
  def handle_call({:route, key, message}, _from, state) do
    if state.partitions == [] do
      {:reply, {:error, :no_partitions}, state}
    else
      index = compute_partition(key, length(state.partitions))
      {_index, pid} = Enum.at(state.partitions, index)
      state.worker_module.process(pid, key, message)
      new_counts = Map.update(state.message_counts, index, 1, &(&1 + 1))
      {:reply, :ok, %{state | message_counts: new_counts}}
    end
  end

  @impl GenServer
  def handle_call({:partition_for, key}, _from, state) do
    if state.partitions == [] do
      {:reply, {:error, :no_partitions}, state}
    else
      {:reply, {:ok, compute_partition(key, length(state.partitions))}, state}
    end
  end

  @impl GenServer
  def handle_call(:partition_stats, _from, state) do
    stats =
      Enum.map(state.partitions, fn {index, pid} ->
        %{
          partition: index,
          pid: pid,
          message_count: Map.get(state.message_counts, index, 0)
        }
      end)

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_call({:resize, new_count}, _from, state) do
    Enum.each(state.partitions, fn {_index, pid} ->
      DynamicSupervisor.terminate_child(DataPipeline.PartitionSupervisor, pid)
    end)

    new_partitions = start_partitions(new_count, state.worker_module)
    {:reply, :ok, %{state | partitions: new_partitions, message_counts: %{}}}
  end

  defp start_partitions(count, worker_module) do
    Enum.map(0..(count - 1), fn index ->
      {:ok, pid} =
        DynamicSupervisor.start_child(
          DataPipeline.PartitionSupervisor,
          {worker_module, partition: index}
        )

      {index, pid}
    end)
  end

  defp compute_partition(key, partition_count) do
    :erlang.phash2(key, partition_count)
  end
end
```
