```elixir
defmodule Projections.ReadModelProjector do
  @moduledoc """
  A supervised GenServer that consumes a stream of persisted domain events
  and maintains a denormalised read-model table. Tracks the last processed
  sequence number to support crash recovery and resumable projection.
  """

  use GenServer

  alias Projections.{Repo, Checkpoint, EventStream}

  @poll_interval_ms 500
  @batch_size 100

  @type handler_module :: module()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec reset(atom()) :: :ok
  def reset(name) when is_atom(name) do
    GenServer.call(name, :reset)
  end

  @spec current_position(atom()) :: non_neg_integer()
  def current_position(name) when is_atom(name) do
    GenServer.call(name, :position)
  end

  @impl GenServer
  def init(opts) do
    projection_name = Keyword.fetch!(opts, :name)
    handler = Keyword.fetch!(opts, :handler)
    stream_id = Keyword.get(opts, :stream_id)

    position = Checkpoint.load(projection_name)
    schedule_poll()

    {:ok,
     %{
       name: projection_name,
       handler: handler,
       stream_id: stream_id,
       position: position
     }}
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    Checkpoint.store(state.name, 0)
    state.handler.reset()
    {:reply, :ok, %{state | position: 0}}
  end

  def handle_call(:position, _from, state) do
    {:reply, state.position, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    new_position = process_batch(state)
    schedule_poll()
    {:noreply, %{state | position: new_position}}
  end

  @spec process_batch(map()) :: non_neg_integer()
  defp process_batch(state) do
    events = EventStream.fetch_after(state.stream_id, state.position, @batch_size)

    case events do
      [] ->
        state.position

      _ ->
        Repo.transaction(fn ->
          Enum.each(events, fn event ->
            state.handler.handle(event.event_type, event.payload, event.metadata)
          end)

          last_seq = events |> List.last() |> Map.fetch!(:sequence_number)
          Checkpoint.store(state.name, last_seq)
          last_seq
        end)
        |> case do
          {:ok, position} -> position
          {:error, _} -> state.position
        end
    end
  end

  @spec schedule_poll() :: reference()
  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)
end
```
