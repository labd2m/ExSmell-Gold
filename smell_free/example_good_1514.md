```elixir
defmodule Search.IndexWorker do
  @moduledoc """
  GenServer responsible for batching and flushing document index operations
  to an external search backend.

  Documents are buffered in-process and flushed either when the buffer
  reaches its configured capacity or when the flush interval elapses,
  whichever comes first. This minimizes round-trips to the search backend
  under high write throughput.
  """

  use GenServer

  require Logger

  alias Search.Backend

  @default_flush_interval_ms 5_000
  @default_max_buffer_size 100

  @type index_name :: String.t()
  @type document :: map()

  @type state :: %{
          index_name: index_name(),
          buffer: [document()],
          flush_interval_ms: pos_integer(),
          max_buffer_size: pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    index_name = Keyword.fetch!(opts, :index_name)
    GenServer.start_link(__MODULE__, opts, name: via(index_name))
  end

  @doc """
  Enqueues a document for indexing. The document will be flushed
  to the backend either at the next scheduled interval or when
  the buffer is full.
  """
  @spec enqueue(index_name(), document()) :: :ok
  def enqueue(index_name, document) when is_binary(index_name) and is_map(document) do
    GenServer.cast(via(index_name), {:enqueue, document})
  end

  @doc """
  Forces an immediate flush of the current buffer for the given index.
  """
  @spec flush(index_name()) :: :ok
  def flush(index_name) when is_binary(index_name) do
    GenServer.call(via(index_name), :flush)
  end

  @impl GenServer
  def init(opts) do
    index_name = Keyword.fetch!(opts, :index_name)
    flush_interval = Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms)
    max_buffer = Keyword.get(opts, :max_buffer_size, @default_max_buffer_size)

    schedule_flush(flush_interval)

    state = %{
      index_name: index_name,
      buffer: [],
      flush_interval_ms: flush_interval,
      max_buffer_size: max_buffer
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:enqueue, document}, %{buffer: buffer, max_buffer_size: max} = state) do
    updated_buffer = [document | buffer]

    if length(updated_buffer) >= max do
      flush_buffer(updated_buffer, state.index_name)
      {:noreply, %{state | buffer: []}}
    else
      {:noreply, %{state | buffer: updated_buffer}}
    end
  end

  @impl GenServer
  def handle_call(:flush, _from, %{buffer: buffer, index_name: index_name} = state) do
    flush_buffer(buffer, index_name)
    {:reply, :ok, %{state | buffer: []}}
  end

  @impl GenServer
  def handle_info(:scheduled_flush, %{buffer: [], flush_interval_ms: interval} = state) do
    schedule_flush(interval)
    {:noreply, state}
  end

  def handle_info(:scheduled_flush, %{buffer: buffer, index_name: index, flush_interval_ms: interval} = state) do
    flush_buffer(buffer, index)
    schedule_flush(interval)
    {:noreply, %{state | buffer: []}}
  end

  @spec flush_buffer([document()], index_name()) :: :ok
  defp flush_buffer([], _index_name), do: :ok

  defp flush_buffer(documents, index_name) do
    ordered = Enum.reverse(documents)

    case Backend.bulk_index(index_name, ordered) do
      :ok ->
        Logger.debug("Flushed #{length(ordered)} documents to index #{index_name}")

      {:error, reason} ->
        Logger.error("Flush to index #{index_name} failed: #{inspect(reason)}")
    end
  end

  @spec schedule_flush(pos_integer()) :: reference()
  defp schedule_flush(interval_ms) do
    Process.send_after(self(), :scheduled_flush, interval_ms)
  end

  defp via(index_name) do
    {:via, Registry, {Search.Registry, index_name}}
  end
end
```
