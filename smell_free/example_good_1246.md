```elixir
defmodule Streaming.Pipeline.BufferedSink do
  @moduledoc """
  A GenServer-backed buffered sink that accumulates incoming records and
  flushes them to a downstream writer when a size or time threshold is reached.
  Suitable for batching writes to databases or external APIs.
  """

  use GenServer

  @default_max_buffer 500
  @default_flush_interval_ms 10_000

  @type record :: map()
  @type writer :: module()
  @type state :: %{
          buffer: [record()],
          writer: writer(),
          max_buffer: pos_integer(),
          flush_interval_ms: pos_integer()
        }

  @doc """
  Starts the BufferedSink linked to the calling process.

  ## Options
    - `:writer` - module with `write_batch/1` callback (required)
    - `:max_buffer` - flush when buffer reaches this size (default: 500)
    - `:flush_interval_ms` - time-based flush interval (default: 10_000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Pushes a single record into the buffer. Triggers a flush if the buffer is full.
  """
  @spec push(record()) :: :ok
  def push(record) when is_map(record) do
    GenServer.cast(__MODULE__, {:push, record})
  end

  @doc """
  Pushes a batch of records. Triggers a flush for every full buffer threshold crossed.
  """
  @spec push_batch([record()]) :: :ok
  def push_batch(records) when is_list(records) do
    GenServer.cast(__MODULE__, {:push_batch, records})
  end

  @doc """
  Forces an immediate flush regardless of buffer state.
  """
  @spec flush() :: :ok | {:error, term()}
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @impl GenServer
  def init(opts) do
    writer = Keyword.fetch!(opts, :writer)
    max_buffer = Keyword.get(opts, :max_buffer, @default_max_buffer)
    flush_interval_ms = Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms)
    schedule_flush(flush_interval_ms)

    {:ok, %{buffer: [], writer: writer, max_buffer: max_buffer, flush_interval_ms: flush_interval_ms}}
  end

  @impl GenServer
  def handle_cast({:push, record}, state) do
    new_buffer = [record | state.buffer]
    {:noreply, maybe_flush(state, new_buffer)}
  end

  @impl GenServer
  def handle_cast({:push_batch, records}, state) do
    new_buffer = Enum.reduce(records, state.buffer, fn r, acc -> [r | acc] end)
    {:noreply, maybe_flush(state, new_buffer)}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    result = do_flush(state.buffer, state.writer)
    {:reply, result, %{state | buffer: []}}
  end

  @impl GenServer
  def handle_info(:scheduled_flush, state) do
    do_flush(state.buffer, state.writer)
    schedule_flush(state.flush_interval_ms)
    {:noreply, %{state | buffer: []}}
  end

  defp maybe_flush(state, buffer) when length(buffer) >= state.max_buffer do
    do_flush(buffer, state.writer)
    %{state | buffer: []}
  end

  defp maybe_flush(state, buffer), do: %{state | buffer: buffer}

  defp do_flush([], _writer), do: :ok

  defp do_flush(buffer, writer) do
    buffer
    |> Enum.reverse()
    |> writer.write_batch()
  end

  defp schedule_flush(interval) do
    Process.send_after(self(), :scheduled_flush, interval)
  end
end
```
