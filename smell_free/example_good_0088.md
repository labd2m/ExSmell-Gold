# File: `example_good_88.md`

```elixir
defmodule Upload.ChunkAssembler do
  @moduledoc """
  GenServer that tracks and assembles multi-part chunked file uploads.

  Each upload session is identified by a unique session ID. Chunks
  may arrive out of order and are buffered until all parts have been
  received, at which point the assembled file is passed to a
  configurable completion callback.

  Stale incomplete sessions are pruned on a periodic timer to prevent
  unbounded memory growth from abandoned uploads.
  """

  use GenServer

  require Logger

  @session_ttl_ms 1_800_000
  @cleanup_interval_ms 300_000

  @type session_id :: String.t()
  @type chunk_index :: non_neg_integer()

  @type session :: %{
          total_chunks: pos_integer(),
          received: %{chunk_index() => binary()},
          on_complete: (binary() -> :ok | {:error, term()}),
          created_at_ms: integer()
        }

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Initialises a new upload session.

  `on_complete/1` will be called with the fully assembled binary when
  all chunks have been received. Returns `{:ok, session_id}`.
  """
  @spec start_session(pos_integer(), (binary() -> any())) ::
          {:ok, session_id()} | {:error, :invalid_args}
  def start_session(total_chunks, on_complete)
      when is_integer(total_chunks) and total_chunks > 0 and is_function(on_complete, 1) do
    GenServer.call(__MODULE__, {:start_session, total_chunks, on_complete})
  end

  @doc """
  Submits a chunk for an existing upload session.

  `index` is zero-based. Submitting the final outstanding chunk triggers
  assembly and calls `on_complete`. Returns `:ok`, `{:error, :session_not_found}`,
  or `{:error, :index_out_of_range}`.
  """
  @spec put_chunk(session_id(), chunk_index(), binary()) ::
          :ok | {:error, :session_not_found | :index_out_of_range}
  def put_chunk(session_id, index, data)
      when is_binary(session_id) and is_integer(index) and index >= 0 and is_binary(data) do
    GenServer.call(__MODULE__, {:put_chunk, session_id, index, data})
  end

  @doc """
  Returns progress information for an active upload session.
  """
  @spec progress(session_id()) ::
          {:ok, %{received: non_neg_integer(), total: pos_integer()}}
          | {:error, :session_not_found}
  def progress(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:progress, session_id})
  end

  @impl GenServer
  def init(_opts) do
    schedule_cleanup()
    {:ok, %{sessions: %{}}}
  end

  @impl GenServer
  def handle_call({:start_session, total_chunks, on_complete}, _from, state) do
    session_id = generate_session_id()

    session = %{
      total_chunks: total_chunks,
      received: %{},
      on_complete: on_complete,
      created_at_ms: System.monotonic_time(:millisecond)
    }

    {:reply, {:ok, session_id}, put_in(state, [:sessions, session_id], session)}
  end

  @impl GenServer
  def handle_call({:put_chunk, session_id, index, data}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, session} -> handle_chunk(state, session_id, session, index, data)
      :error -> {:reply, {:error, :session_not_found}, state}
    end
  end

  @impl GenServer
  def handle_call({:progress, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, session} ->
        info = %{received: map_size(session.received), total: session.total_chunks}
        {:reply, {:ok, info}, state}

      :error ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    cutoff = System.monotonic_time(:millisecond) - @session_ttl_ms
    active = Map.reject(state.sessions, fn {_id, s} -> s.created_at_ms < cutoff end)
    stale_count = map_size(state.sessions) - map_size(active)
    if stale_count > 0, do: Logger.info("Pruned #{stale_count} stale upload sessions")
    schedule_cleanup()
    {:noreply, %{state | sessions: active}}
  end

  defp handle_chunk(state, session_id, session, index, data) do
    if index >= session.total_chunks do
      {:reply, {:error, :index_out_of_range}, state}
    else
      updated_session = put_in(session, [:received, index], data)

      if map_size(updated_session.received) == updated_session.total_chunks do
        assemble_and_complete(state, session_id, updated_session)
      else
        {:reply, :ok, put_in(state, [:sessions, session_id], updated_session)}
      end
    end
  end

  defp assemble_and_complete(state, session_id, session) do
    assembled =
      0..(session.total_chunks - 1)
      |> Enum.map(&Map.fetch!(session.received, &1))
      |> IO.iodata_to_binary()

    Task.Supervisor.start_child(Upload.TaskSupervisor, fn ->
      session.on_complete.(assembled)
    end)

    {:reply, :ok, update_in(state, [:sessions], &Map.delete(&1, session_id))}
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
```
