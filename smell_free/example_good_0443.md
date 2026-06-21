```elixir
defmodule Metrics.DistributedCounter do
  @moduledoc """
  A cluster-wide, eventually consistent counter backed by a Horde-managed
  `DynamicSupervisor` and per-node GenServer shards. Each node maintains
  a local increment accumulator; global totals are computed by aggregating
  all shard states on demand. This avoids synchronous cross-node calls
  on the hot path while still providing accurate aggregate counts for
  reporting and dashboards.
  """

  use GenServer

  require Logger

  @type counter_name :: binary()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  @doc """
  Atomically increments `counter_name` on the local node by `amount`.
  Starts a shard for the counter on this node if one is not already running.
  Returns `:ok`.
  """
  @spec increment(counter_name(), pos_integer()) :: :ok
  def increment(counter_name, amount \\ 1)
      when is_binary(counter_name) and is_integer(amount) and amount > 0 do
    ensure_shard(counter_name)
    GenServer.cast(via(shard_name(counter_name)), {:increment, amount})
  end

  @doc """
  Returns the global aggregate count for `counter_name` by summing
  the current value from every live shard across the cluster.
  """
  @spec total(counter_name()) :: non_neg_integer()
  def total(counter_name) when is_binary(counter_name) do
    pattern = shard_name_pattern(counter_name)

    Horde.Registry.select(Metrics.CounterRegistry, [{{pattern, :_, :_}, [], [:"$1"]}])
    |> Enum.reduce(0, fn pid, acc ->
      try do
        acc + GenServer.call(pid, :count, 1_000)
      catch
        :exit, _ -> acc
      end
    end)
  end

  @doc """
  Returns per-node counts for `counter_name`, useful for debugging skew.
  """
  @spec per_node_counts(counter_name()) :: %{node() => non_neg_integer()}
  def per_node_counts(counter_name) when is_binary(counter_name) do
    pattern = shard_name_pattern(counter_name)

    Horde.Registry.select(Metrics.CounterRegistry, [{{pattern, :_, :_}, [], [:"$1"]}])
    |> Enum.reduce(%{}, fn pid, acc ->
      try do
        {node_name, count} = GenServer.call(pid, :node_count, 1_000)
        Map.put(acc, node_name, count)
      catch
        :exit, _ -> acc
      end
    end)
  end

  @doc """
  Resets the local shard for `counter_name` to zero. Does not affect
  other nodes; call on all nodes to achieve a global reset.
  """
  @spec reset_local(counter_name()) :: :ok
  def reset_local(counter_name) when is_binary(counter_name) do
    GenServer.cast(via(shard_name(counter_name)), :reset)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    counter_name = Keyword.fetch!(opts, :name)
    {:ok, %{name: counter_name, count: 0, node: Node.self()}}
  end

  @impl GenServer
  def handle_cast({:increment, amount}, state) do
    {:noreply, %{state | count: state.count + amount}}
  end

  def handle_cast(:reset, state) do
    {:noreply, %{state | count: 0}}
  end

  @impl GenServer
  def handle_call(:count, _from, state) do
    {:reply, state.count, state}
  end

  def handle_call(:node_count, _from, state) do
    {:reply, {state.node, state.count}, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp ensure_shard(counter_name) do
    spec = {__MODULE__, name: shard_name(counter_name)}

    case Horde.DynamicSupervisor.start_child(Metrics.CounterSupervisor, spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} ->
        Logger.warning("Failed to start counter shard", counter: counter_name, reason: inspect(reason))
    end
  end

  defp shard_name(counter_name) do
    "#{counter_name}::#{Node.self()}"
  end

  defp shard_name_pattern(counter_name) do
    prefix = "#{counter_name}::"
    :"#{prefix}_"
  end

  defp via(name), do: {:via, Horde.Registry, {Metrics.CounterRegistry, name}}
end
```
