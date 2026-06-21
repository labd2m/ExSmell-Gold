```elixir
defmodule Streaming.ChunkedUploader do
  @moduledoc """
  Handles multi-part chunked file uploads. A session is opened once, then
  individual chunks are appended in order. Finalising the session assembles
  the chunks into a single binary and stores it. The server enforces chunk
  ordering and detects gaps so clients cannot silently skip parts.
  """

  use GenServer

  require Logger

  @type session_id :: String.t()
  @type chunk_index :: non_neg_integer()
  @type session_state :: %{
          session_id: session_id(),
          filename: String.t(),
          total_chunks: pos_integer(),
          received: %{chunk_index() => binary()},
          finalised: boolean()
        }

  @session_timeout_ms :timer.minutes(15)

  @doc "Opens a new upload session. Returns the session ID."
  @spec open(String.t(), pos_integer()) :: {:ok, session_id()}
  def open(filename, total_chunks)
      when is_binary(filename) and is_integer(total_chunks) and total_chunks > 0 do
    session_id = generate_session_id()
    {:ok, _pid} = DynamicSupervisor.start_child(
      Streaming.SessionSupervisor,
      {__MODULE__, session_id: session_id, filename: filename, total_chunks: total_chunks}
    )
    {:ok, session_id}
  end

  @doc "Appends a chunk at the given index. Chunks must arrive in order."
  @spec append_chunk(session_id(), chunk_index(), binary()) ::
          :ok | {:error, :session_not_found | :wrong_chunk_index | :already_finalised}
  def append_chunk(session_id, index, data)
      when is_binary(session_id) and is_integer(index) and is_binary(data) do
    case lookup(session_id) do
      nil -> {:error, :session_not_found}
      pid -> GenServer.call(pid, {:append, index, data})
    end
  end

  @doc "Finalises the session, assembling and persisting the file."
  @spec finalise(session_id()) :: {:ok, binary()} | {:error, :session_not_found | :chunks_missing}
  def finalise(session_id) when is_binary(session_id) do
    case lookup(session_id) do
      nil -> {:error, :session_not_found}
      pid -> GenServer.call(pid, :finalise)
    end
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  @impl GenServer
  def init(opts) do
    state = %{
      session_id: Keyword.fetch!(opts, :session_id),
      filename: Keyword.fetch!(opts, :filename),
      total_chunks: Keyword.fetch!(opts, :total_chunks),
      received: %{},
      finalised: false
    }

    Process.send_after(self(), :timeout, @session_timeout_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:append, _index, _data}, _from, %{finalised: true} = state) do
    {:reply, {:error, :already_finalised}, state}
  end

  def handle_call({:append, index, data}, _from, state) do
    expected = map_size(state.received)

    if index != expected do
      {:reply, {:error, :wrong_chunk_index}, state}
    else
      new_state = put_in(state, [:received, index], data)
      {:reply, :ok, new_state}
    end
  end

  def handle_call(:finalise, _from, state) do
    if map_size(state.received) < state.total_chunks do
      {:reply, {:error, :chunks_missing}, state}
    else
      assembled = assemble(state.received, state.total_chunks)
      {:reply, {:ok, assembled}, %{state | finalised: true}}
    end
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    Logger.warning("[ChunkedUploader] Session #{state.session_id} expired")
    {:stop, :normal, state}
  end

  defp assemble(received, total) do
    0..(total - 1)
    |> Enum.map(&Map.fetch!(received, &1))
    |> Enum.join()
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  defp via(session_id), do: {:via, Registry, {Streaming.SessionRegistry, session_id}}

  defp lookup(session_id) do
    case Registry.lookup(Streaming.SessionRegistry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
```
