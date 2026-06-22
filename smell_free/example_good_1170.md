**File:** `example_good_1170.md`

```elixir
defmodule Analytics.Event do
  @moduledoc "Represents a single analytics event captured from a client."

  @enforce_keys [:name, :source, :occurred_at]
  defstruct [:name, :source, :occurred_at, :user_id, :session_id, :properties]

  @type t :: %__MODULE__{
          name: String.t(),
          source: String.t(),
          occurred_at: DateTime.t(),
          user_id: String.t() | nil,
          session_id: String.t() | nil,
          properties: map()
        }

  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(name, source, opts \\ []) when is_binary(name) and is_binary(source) do
    %__MODULE__{
      name: name,
      source: source,
      occurred_at: Keyword.get(opts, :occurred_at, DateTime.utc_now()),
      user_id: Keyword.get(opts, :user_id),
      session_id: Keyword.get(opts, :session_id),
      properties: Keyword.get(opts, :properties, %{})
    }
  end
end

defmodule Analytics.Buffer do
  @moduledoc """
  A GenServer that buffers analytics events in memory and flushes them
  to the configured sink in batches, either by count threshold or timer.
  """

  use GenServer

  require Logger

  alias Analytics.Event

  @default_batch_size 200
  @default_flush_interval_ms :timer.seconds(10)

  @type state :: %{
          buffer: [Event.t()],
          batch_size: pos_integer(),
          flush_interval_ms: pos_integer(),
          sink: module()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec track(Event.t()) :: :ok
  def track(%Event{} = event) do
    GenServer.cast(__MODULE__, {:track, event})
  end

  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @spec buffer_size() :: non_neg_integer()
  def buffer_size do
    GenServer.call(__MODULE__, :buffer_size)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      buffer: [],
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      flush_interval_ms: Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms),
      sink: Keyword.fetch!(opts, :sink)
    }

    schedule_flush(state.flush_interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:track, event}, %{buffer: buffer, batch_size: batch_size} = state) do
    updated_buffer = [event | buffer]

    if length(updated_buffer) >= batch_size do
      emit_batch(updated_buffer, state.sink)
      {:noreply, %{state | buffer: []}}
    else
      {:noreply, %{state | buffer: updated_buffer}}
    end
  end

  @impl GenServer
  def handle_call(:flush, _from, %{buffer: []} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:flush, _from, %{buffer: buffer} = state) do
    emit_batch(buffer, state.sink)
    {:reply, :ok, %{state | buffer: []}}
  end

  def handle_call(:buffer_size, _from, %{buffer: buffer} = state) do
    {:reply, length(buffer), state}
  end

  @impl GenServer
  def handle_info(:scheduled_flush, %{buffer: []} = state) do
    schedule_flush(state.flush_interval_ms)
    {:noreply, state}
  end

  def handle_info(:scheduled_flush, %{buffer: buffer} = state) do
    emit_batch(buffer, state.sink)
    schedule_flush(state.flush_interval_ms)
    {:noreply, %{state | buffer: []}}
  end

  defp emit_batch(events, sink) do
    batch = Enum.reverse(events)

    case sink.write(batch) do
      :ok ->
        Logger.debug("Analytics batch of #{length(batch)} events flushed successfully")

      {:error, reason} ->
        Logger.error("Analytics batch flush failed: #{inspect(reason)}")
    end
  end

  defp schedule_flush(interval_ms) do
    Process.send_after(self(), :scheduled_flush, interval_ms)
  end
end

defmodule Analytics.Sinks.Stdout do
  @moduledoc "A development analytics sink that writes events to stdout."

  alias Analytics.Event

  @spec write([Event.t()]) :: :ok
  def write(events) when is_list(events) do
    Enum.each(events, fn event ->
      IO.puts("[Analytics] #{event.name} from #{event.source} at #{DateTime.to_iso8601(event.occurred_at)}")
    end)

    :ok
  end
end
```
