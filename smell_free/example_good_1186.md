```elixir
defmodule Pipeline.WorkerSupervisor do
  @moduledoc """
  Supervises dynamically spawned ingestion workers.
  Workers are registered by source ID for targeted message routing.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: 100)
  end

  @spec start_worker(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_worker(source_id, opts \\ []) when is_binary(source_id) do
    child = Pipeline.Worker.child_spec(%{source_id: source_id, opts: opts})
    DynamicSupervisor.start_child(__MODULE__, child)
  end

  @spec stop_worker(String.t()) :: :ok | {:error, :not_found}
  def stop_worker(source_id) when is_binary(source_id) do
    case Registry.lookup(Pipeline.Registry, source_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end

  @spec active_count() :: non_neg_integer()
  def active_count do
    DynamicSupervisor.count_children(__MODULE__).active
  end
end

defmodule Pipeline.Worker do
  @moduledoc """
  Stateful worker that accumulates records from one named source and
  flushes them to the configured sink when the buffer reaches capacity
  or when explicitly requested.
  """

  use GenServer

  @buffer_limit 200

  @type state :: %{
          source_id: String.t(),
          buffer: list(map()),
          flushed_total: non_neg_integer()
        }

  @spec child_spec(map()) :: Supervisor.child_spec()
  def child_spec(%{source_id: source_id} = args) do
    %{
      id: {__MODULE__, source_id},
      start: {__MODULE__, :start_link, [args]},
      restart: :transient,
      shutdown: 10_000
    }
  end

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{source_id: source_id} = args) do
    GenServer.start_link(__MODULE__, args, name: via(source_id))
  end

  @spec push(String.t(), map()) :: :ok | {:error, :worker_not_found}
  def push(source_id, record) when is_binary(source_id) and is_map(record) do
    case Registry.lookup(Pipeline.Registry, source_id) do
      [{pid, _}] -> GenServer.cast(pid, {:push, record})
      [] -> {:error, :worker_not_found}
    end
  end

  @spec flush(String.t()) :: {:ok, non_neg_integer()} | {:error, :worker_not_found}
  def flush(source_id) when is_binary(source_id) do
    case Registry.lookup(Pipeline.Registry, source_id) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :flush)}
      [] -> {:error, :worker_not_found}
    end
  end

  @spec stats(String.t()) :: {:ok, map()} | {:error, :worker_not_found}
  def stats(source_id) when is_binary(source_id) do
    case Registry.lookup(Pipeline.Registry, source_id) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :stats)}
      [] -> {:error, :worker_not_found}
    end
  end

  @impl GenServer
  def init(%{source_id: source_id}) do
    {:ok, %{source_id: source_id, buffer: [], flushed_total: 0}}
  end

  @impl GenServer
  def handle_cast({:push, record}, %{buffer: buf} = state) when length(buf) < @buffer_limit do
    {:noreply, %{state | buffer: [record | buf]}}
  end

  def handle_cast({:push, record}, state) do
    count = flush_buffer(state.buffer)
    {:noreply, %{state | buffer: [record], flushed_total: state.flushed_total + count}}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    count = flush_buffer(state.buffer)
    {:reply, count, %{state | buffer: [], flushed_total: state.flushed_total + count}}
  end

  def handle_call(:stats, _from, state) do
    reply = %{
      source_id: state.source_id,
      buffered: length(state.buffer),
      flushed_total: state.flushed_total
    }
    {:reply, reply, state}
  end

  defp flush_buffer([]), do: 0

  defp flush_buffer(buffer) do
    records = Enum.reverse(buffer)
    Pipeline.Sink.write_batch(records)
    length(records)
  end

  defp via(source_id) do
    {:via, Registry, {Pipeline.Registry, source_id}}
  end
end
```
