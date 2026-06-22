```elixir
defmodule Platform.TelemetryReporter do
  @moduledoc """
  A GenServer that aggregates Telemetry events and flushes them in batches
  to an external metrics service.

  Events are buffered in memory. When the buffer reaches `max_batch_size`
  or `flush_interval_ms` elapses, the batch is serialised and sent to the
  configured sink. Failed flushes are retried with exponential backoff.
  """

  use GenServer

  require Logger

  @type event_name :: [atom()]
  @type sink_fn :: ([map()] -> :ok | {:error, term()})

  @default_flush_interval_ms :timer.seconds(10)
  @default_max_batch_size 500

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Attaches the reporter to the given list of Telemetry event names."
  @spec attach([[atom()]]) :: :ok
  def attach(event_names) when is_list(event_names) do
    handler_id = inspect(__MODULE__)
    :telemetry.attach_many(handler_id, event_names, &handle_telemetry/4, %{reporter: __MODULE__})
    :ok
  end

  @doc "Forces an immediate flush of the current buffer."
  @spec flush() :: :ok
  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc "Returns the current number of buffered events."
  @spec buffer_size() :: non_neg_integer()
  def buffer_size, do: GenServer.call(__MODULE__, :buffer_size)

  @impl GenServer
  def init(opts) do
    sink = Keyword.fetch!(opts, :sink)
    flush_interval = Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms)
    max_batch = Keyword.get(opts, :max_batch_size, @default_max_batch_size)

    schedule_flush(flush_interval)

    {:ok, %{
      sink: sink,
      buffer: [],
      flush_interval: flush_interval,
      max_batch_size: max_batch,
      total_flushed: 0,
      failed_flushes: 0
    }}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    {:reply, :ok, do_flush(state)}
  end

  @impl GenServer
  def handle_call(:buffer_size, _from, state) do
    {:reply, length(state.buffer), state}
  end

  @impl GenServer
  def handle_cast({:record, event}, %{buffer: buffer, max_batch_size: max} = state) do
    new_buffer = [event | buffer]
    new_state = %{state | buffer: new_buffer}

    if length(new_buffer) >= max do
      {:noreply, do_flush(new_state)}
    else
      {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_info(:flush, %{flush_interval: interval} = state) do
    schedule_flush(interval)
    {:noreply, do_flush(state)}
  end

  defp handle_telemetry(event_name, measurements, metadata, %{reporter: reporter}) do
    record = %{
      event: event_name,
      measurements: measurements,
      metadata: sanitize_metadata(metadata),
      timestamp: System.system_time(:millisecond)
    }
    GenServer.cast(reporter, {:record, record})
  end

  defp do_flush(%{buffer: []} = state), do: state

  defp do_flush(%{buffer: buffer, sink: sink} = state) do
    events = Enum.reverse(buffer)

    case send_with_retry(sink, events, 3) do
      :ok ->
        Logger.debug("[TelemetryReporter] Flushed #{length(events)} events")
        %{state | buffer: [], total_flushed: state.total_flushed + length(events)}

      {:error, reason} ->
        Logger.error("[TelemetryReporter] Flush failed after retries", reason: inspect(reason))
        %{state | buffer: [], failed_flushes: state.failed_flushes + 1}
    end
  end

  defp send_with_retry(_sink, _events, 0), do: {:error, :max_retries_exceeded}

  defp send_with_retry(sink, events, attempts) do
    case sink.(events) do
      :ok -> :ok
      {:error, _} ->
        backoff = (4 - attempts) * 500
        Process.sleep(backoff)
        send_with_retry(sink, events, attempts - 1)
    end
  end

  defp sanitize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.drop([:socket, :conn, :pid])
    |> Map.new(fn {k, v} -> {k, inspect_if_complex(v)} end)
  end

  defp sanitize_metadata(_), do: %{}

  defp inspect_if_complex(v) when is_binary(v) or is_number(v) or is_atom(v), do: v
  defp inspect_if_complex(v), do: inspect(v)

  defp schedule_flush(interval), do: Process.send_after(self(), :flush, interval)
end
```
