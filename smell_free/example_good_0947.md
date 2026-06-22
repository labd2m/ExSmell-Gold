```elixir
defmodule Comms.BroadcastThrottler do
  @moduledoc """
  Throttles outbound broadcast messages to prevent flooding connected
  clients during high-traffic events. Messages are buffered per topic
  and flushed at a configurable maximum rate. When the buffer is full
  the oldest message is evicted so the most recent state is always
  delivered to clients rather than stale data.
  """

  use GenServer

  require Logger

  @type topic :: String.t()
  @type message :: term()
  @type flush_fn :: (topic(), [message()] -> :ok)

  @default_rate_ms 100
  @default_buffer_size 20

  @doc "Starts the broadcast throttler with a flush function."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Queues a message for `topic`. Evicts the oldest message when the buffer is full."
  @spec enqueue(GenServer.server(), topic(), message()) :: :ok
  def enqueue(server \\ __MODULE__, topic, message) when is_binary(topic) do
    GenServer.cast(server, {:enqueue, topic, message})
  end

  @doc "Returns the current buffer depth across all topics."
  @spec total_buffered(GenServer.server()) :: non_neg_integer()
  def total_buffered(server \\ __MODULE__) do
    GenServer.call(server, :total_buffered)
  end

  @impl GenServer
  def init(opts) do
    flush_fn = Keyword.fetch!(opts, :flush_fn)
    rate_ms = Keyword.get(opts, :rate_ms, @default_rate_ms)
    buffer_size = Keyword.get(opts, :buffer_size, @default_buffer_size)
    Process.send_after(self(), :flush, rate_ms)

    {:ok, %{buffers: %{}, flush_fn: flush_fn, rate_ms: rate_ms, buffer_size: buffer_size}}
  end

  @impl GenServer
  def handle_cast({:enqueue, topic, message}, state) do
    current = Map.get(state.buffers, topic, [])
    updated =
      if length(current) >= state.buffer_size do
        tl(current) ++ [message]
      else
        current ++ [message]
      end

    {:noreply, %{state | buffers: Map.put(state.buffers, topic, updated)}}
  end

  @impl GenServer
  def handle_call(:total_buffered, _from, state) do
    count = state.buffers |> Map.values() |> Enum.sum_by(&length/1)
    {:reply, count, state}
  end

  @impl GenServer
  def handle_info(:flush, %{rate_ms: rate} = state) do
    Enum.each(state.buffers, fn {topic, messages} ->
      unless Enum.empty?(messages), do: state.flush_fn.(topic, messages)
    end)

    Process.send_after(self(), :flush, rate)
    {:noreply, %{state | buffers: %{}}}
  end
end
```
