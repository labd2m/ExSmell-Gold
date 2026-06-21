```elixir
defmodule ProcessRegistry do
  @moduledoc """
  A named process registry that monitors every registered process and
  automatically removes stale entries when a process exits.

  Reads use `:ets.lookup/2` directly against a public table so lookups
  are always lock-free. Registrations, deregistrations, and cleanup on
  process exit are serialised through the GenServer. Duplicate names are
  rejected to enforce unique ownership of each name.
  """

  use GenServer

  @table __MODULE__

  @type name :: term()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(name(), pid()) :: :ok | {:error, {:already_registered, pid()}}
  def register(name, pid \\ self()) when is_pid(pid) do
    GenServer.call(__MODULE__, {:register, name, pid})
  end

  @spec unregister(name()) :: :ok
  def unregister(name) do
    GenServer.call(__MODULE__, {:unregister, name})
  end

  @spec lookup(name()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(name) do
    case :ets.lookup(@table, name) do
      [{^name, pid, _ref}] ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_found}

      [] ->
        {:error, :not_found}
    end
  end

  @spec registered_names() :: [name()]
  def registered_names do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {name, _pid, _ref} -> name end)
  end

  @spec count() :: non_neg_integer()
  def count, do: :ets.info(@table, :size)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{monitors: %{}}}
  end

  @impl GenServer
  def handle_call({:register, name, pid}, _from, state) do
    case :ets.lookup(@table, name) do
      [{^name, existing_pid, _ref}] ->
        {:reply, {:error, {:already_registered, existing_pid}}, state}

      [] ->
        ref = Process.monitor(pid)
        :ets.insert(@table, {name, pid, ref})
        {:reply, :ok, %{state | monitors: Map.put(state.monitors, ref, name)}}
    end
  end

  def handle_call({:unregister, name}, _from, state) do
    state =
      case :ets.lookup(@table, name) do
        [{^name, _pid, ref}] ->
          Process.demonitor(ref, [:flush])
          :ets.delete(@table, name)
          %{state | monitors: Map.delete(state.monitors, ref)}

        [] ->
          state
      end

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state =
      case Map.fetch(state.monitors, ref) do
        {:ok, name} ->
          :ets.delete(@table, name)
          %{state | monitors: Map.delete(state.monitors, ref)}

        :error ->
          state
      end

    {:noreply, state}
  end
end
```
