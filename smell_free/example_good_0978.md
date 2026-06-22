```elixir
defmodule Relay.MessageRelay do
  @moduledoc """
  A supervised GenServer that relays messages from a fast producer to a
  potentially slower consumer, applying back-pressure by suspending demand
  from the producer when the internal buffer reaches its high-water mark.
  The relay resumes demand automatically when the buffer drains below the
  low-water mark, preventing both producer overflow and consumer starvation.
  All relay state transitions are observable via telemetry.
  """

  use GenServer

  require Logger

  @type relay_opts :: [
          high_watermark: pos_integer(),
          low_watermark: pos_integer(),
          producer: GenServer.server(),
          consumer: GenServer.server()
        ]

  @default_high_watermark 1_000
  @default_low_watermark 200

  @telemetry_prefix [:relay, :message_relay]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(relay_opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Forwards `message` from the producer into the relay buffer.
  Returns `:ok` immediately; back-pressure is applied by suspending
  demand at the producer level rather than blocking the caller.
  """
  @spec relay(GenServer.server(), term()) :: :ok
  def relay(relay \\ __MODULE__, message) do
    GenServer.cast(relay, {:relay, message})
  end

  @doc """
  Returns the current buffer depth and flow-control state.
  """
  @spec status(GenServer.server()) :: %{depth: non_neg_integer(), flow: :running | :paused}
  def status(relay \\ __MODULE__) do
    GenServer.call(relay, :status)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    high = Keyword.get(opts, :high_watermark, @default_high_watermark)
    low = Keyword.get(opts, :low_watermark, @default_low_watermark)

    state = %{
      buffer: :queue.new(),
      high_watermark: high,
      low_watermark: low,
      producer: Keyword.fetch!(opts, :producer),
      consumer: Keyword.fetch!(opts, :consumer),
      flow: :running,
      delivered: 0
    }

    send(self(), :drain)
    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:relay, message}, state) do
    new_queue = :queue.in(message, state.buffer)
    depth = :queue.len(new_queue)
    new_state = %{state | buffer: new_queue}

    emit_telemetry(:buffered, depth, new_state)

    if depth >= state.high_watermark and state.flow == :running do
      Logger.info("Relay high watermark reached, pausing producer", depth: depth)
      GenServer.cast(state.producer, :pause)
      {:noreply, %{new_state | flow: :paused}}
    else
      {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, %{depth: :queue.len(state.buffer), flow: state.flow}, state}
  end

  @impl GenServer
  def handle_info(:drain, state) do
    case :queue.out(state.buffer) do
      {:empty, _} ->
        maybe_resume(state)
        Process.send_after(self(), :drain, 10)
        {:noreply, state}

      {{:value, message}, rest} ->
        case deliver(message, state.consumer) do
          :ok ->
            depth = :queue.len(rest)
            new_state = %{state | buffer: rest, delivered: state.delivered + 1}
            emit_telemetry(:delivered, depth, new_state)

            new_state = maybe_resume(new_state)
            send(self(), :drain)
            {:noreply, new_state}

          {:error, reason} ->
            Logger.warning("Consumer delivery failed, re-queuing", reason: inspect(reason))
            re_queued = :queue.in_r(message, rest)
            Process.send_after(self(), :drain, 500)
            {:noreply, %{state | buffer: re_queued}}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp deliver(message, consumer) do
    try do
      GenServer.call(consumer, {:consume, message}, 5_000)
    catch
      :exit, reason -> {:error, {:consumer_exit, reason}}
    end
  end

  defp maybe_resume(%{flow: :paused, buffer: buf, low_watermark: low, producer: producer} = state) do
    depth = :queue.len(buf)

    if depth <= low do
      Logger.info("Relay low watermark reached, resuming producer", depth: depth)
      GenServer.cast(producer, :resume)
      %{state | flow: :running}
    else
      state
    end
  end

  defp maybe_resume(state), do: state

  defp emit_telemetry(event, depth, state) do
    :telemetry.execute(
      @telemetry_prefix ++ [event],
      %{depth: depth, delivered: state.delivered},
      %{flow: state.flow}
    )
  end
end
```
