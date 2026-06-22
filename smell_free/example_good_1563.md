```elixir
defmodule Events.Stream.ConsumerGroup do
  @moduledoc """
  Manages a supervised pool of event stream consumers operating
  as a coordinated consumer group.

  Each consumer in the group is independently supervised and processes
  partitioned event streams to achieve parallel throughput.
  """

  use Supervisor

  alias Events.Stream.{PartitionConsumer, GroupCoordinator, OffsetRegistry}

  @type group_config :: %{
          group_id: String.t(),
          topics: [String.t()],
          concurrency: pos_integer(),
          handler: module()
        }

  @doc """
  Starts the consumer group supervisor with the given configuration.
  """
  @spec start_link(group_config()) :: Supervisor.on_start()
  def start_link(%{group_id: _} = config) do
    Supervisor.start_link(__MODULE__, config, name: via(config.group_id))
  end

  @impl Supervisor
  def init(%{group_id: group_id, topics: topics, concurrency: concurrency, handler: handler}) do
    offset_registry_child = {OffsetRegistry, group_id: group_id}
    coordinator_child = {GroupCoordinator, group_id: group_id, topics: topics}

    consumer_children =
      for partition <- 0..(concurrency - 1) do
        Supervisor.child_spec(
          {PartitionConsumer,
           group_id: group_id, partition: partition, handler: handler, topics: topics},
          id: {PartitionConsumer, partition}
        )
      end

    children = [offset_registry_child, coordinator_child] ++ consumer_children

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns the current consumer lag across all partitions in the group.
  """
  @spec consumer_lag(String.t()) :: {:ok, %{partition: non_neg_integer(), lag: non_neg_integer()}} | {:error, :group_not_found}
  def consumer_lag(group_id) when is_binary(group_id) do
    case lookup_coordinator(group_id) do
      {:ok, coordinator_pid} -> GroupCoordinator.current_lag(coordinator_pid)
      :error -> {:error, :group_not_found}
    end
  end

  @doc """
  Pauses all consumers in the group, suspending partition processing.
  """
  @spec pause(String.t()) :: :ok | {:error, :group_not_found}
  def pause(group_id) when is_binary(group_id) do
    case lookup_coordinator(group_id) do
      {:ok, coordinator_pid} -> GroupCoordinator.pause(coordinator_pid)
      :error -> {:error, :group_not_found}
    end
  end

  @doc """
  Resumes all paused consumers in the group.
  """
  @spec resume(String.t()) :: :ok | {:error, :group_not_found}
  def resume(group_id) when is_binary(group_id) do
    case lookup_coordinator(group_id) do
      {:ok, coordinator_pid} -> GroupCoordinator.resume(coordinator_pid)
      :error -> {:error, :group_not_found}
    end
  end

  @doc """
  Resets committed offsets for the group to the earliest available position.
  """
  @spec reset_offsets(String.t()) :: :ok | {:error, :group_not_found}
  def reset_offsets(group_id) when is_binary(group_id) do
    case lookup_coordinator(group_id) do
      {:ok, coordinator_pid} -> GroupCoordinator.reset_offsets(coordinator_pid)
      :error -> {:error, :group_not_found}
    end
  end

  defp lookup_coordinator(group_id) do
    case Registry.lookup(Events.Stream.Registry, {GroupCoordinator, group_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp via(group_id) do
    {:via, Registry, {Events.Stream.Registry, {__MODULE__, group_id}}}
  end
end
```
