```elixir
defmodule Audit.Trail.Recorder do
  @moduledoc """
  Records structured audit log entries for sensitive operations.
  Entries are written asynchronously via a supervised GenServer to avoid
  blocking the calling process.
  """

  use GenServer

  alias Audit.Trail.{Entry, Writer}

  @flush_interval_ms 5_000
  @max_buffer_size 200

  @type state :: %{
          buffer: [Entry.t()],
          writer: module(),
          flush_interval_ms: pos_integer(),
          max_buffer_size: pos_integer()
        }

  @doc """
  Starts the Recorder linked to the calling process.

  ## Options
    - `:writer` - module implementing `Writer` behaviour (default: `Audit.Trail.Writers.Database`)
    - `:flush_interval_ms` - how often to flush the buffer (default: 5000)
    - `:max_buffer_size` - force flush when buffer reaches this size (default: 200)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records an audit event for `actor_id` performing `action` on `resource`.
  """
  @spec record(String.t(), atom(), map(), map()) :: :ok
  def record(actor_id, action, resource, metadata \\ %{})
      when is_binary(actor_id) and is_atom(action) and is_map(resource) and is_map(metadata) do
    GenServer.cast(__MODULE__, {:record, actor_id, action, resource, metadata})
  end

  @doc """
  Forces an immediate flush of the buffer to the writer.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @impl GenServer
  def init(opts) do
    writer = Keyword.get(opts, :writer, Audit.Trail.Writers.Database)
    flush_interval_ms = Keyword.get(opts, :flush_interval_ms, @flush_interval_ms)
    max_buffer_size = Keyword.get(opts, :max_buffer_size, @max_buffer_size)
    schedule_flush(flush_interval_ms)

    {:ok,
     %{
       buffer: [],
       writer: writer,
       flush_interval_ms: flush_interval_ms,
       max_buffer_size: max_buffer_size
     }}
  end

  @impl GenServer
  def handle_cast({:record, actor_id, action, resource, metadata}, state) do
    entry = Entry.new(actor_id, action, resource, metadata)
    updated_buffer = [entry | state.buffer]

    if length(updated_buffer) >= state.max_buffer_size do
      do_flush(updated_buffer, state.writer)
      {:noreply, %{state | buffer: []}}
    else
      {:noreply, %{state | buffer: updated_buffer}}
    end
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    do_flush(state.buffer, state.writer)
    {:reply, :ok, %{state | buffer: []}}
  end

  @impl GenServer
  def handle_info(:scheduled_flush, state) do
    do_flush(state.buffer, state.writer)
    schedule_flush(state.flush_interval_ms)
    {:noreply, %{state | buffer: []}}
  end

  defp do_flush([], _writer), do: :ok

  defp do_flush(entries, writer) do
    entries
    |> Enum.reverse()
    |> writer.write_batch()
  end

  defp schedule_flush(interval), do: Process.send_after(self(), :scheduled_flush, interval)
end

defmodule Audit.Trail.Entry do
  @moduledoc """
  An immutable audit log entry capturing actor, action, and resource metadata.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          actor_id: String.t(),
          action: atom(),
          resource: map(),
          metadata: map(),
          occurred_at: DateTime.t()
        }

  defstruct [:id, :actor_id, :action, :resource, :metadata, :occurred_at]

  @spec new(String.t(), atom(), map(), map()) :: t()
  def new(actor_id, action, resource, metadata) do
    %__MODULE__{
      id: Ecto.UUID.generate(),
      actor_id: actor_id,
      action: action,
      resource: resource,
      metadata: metadata,
      occurred_at: DateTime.utc_now()
    }
  end
end
```
