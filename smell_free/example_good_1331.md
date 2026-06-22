```elixir
defmodule Uploads.ResumableSession do
  @moduledoc """
  Manages resumable multi-chunk file upload sessions.

  Each session tracks which chunks have been received, enabling clients to
  resume interrupted uploads from the last confirmed chunk. Sessions expire
  after a configurable TTL if not completed.
  """

  use GenServer

  alias Uploads.ResumableSession.{Session, ChunkRecord, StorageBackend}

  @session_ttl_seconds 3_600
  @cleanup_interval_ms 10 * 60 * 1_000

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Creates a new upload session for a file of the given size.
  """
  @spec create(String.t(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, Session.t()} | {:error, String.t()}
  def create(filename, total_bytes, chunk_size, opts \\ [])
      when is_binary(filename) and is_integer(total_bytes) and total_bytes > 0 and
             is_integer(chunk_size) and chunk_size > 0 do
    owner_id = Keyword.get(opts, :owner_id)
    GenServer.call(__MODULE__, {:create, filename, total_bytes, chunk_size, owner_id})
  end

  @doc """
  Records a received chunk and stores its binary to the backend.
  """
  @spec receive_chunk(String.t(), non_neg_integer(), binary()) ::
          {:ok, :complete | :pending} | {:error, String.t()}
  def receive_chunk(session_id, chunk_index, data)
      when is_binary(session_id) and is_integer(chunk_index) and chunk_index >= 0 and
             is_binary(data) do
    GenServer.call(__MODULE__, {:receive_chunk, session_id, chunk_index, data})
  end

  @doc """
  Returns the status and list of received chunk indices for a session.
  """
  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:status, session_id})
  end

  @doc """
  Cancels an upload session and discards any stored chunks.
  """
  @spec cancel(String.t()) :: :ok | {:error, :not_found}
  def cancel(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:cancel, session_id})
  end

  @impl GenServer
  def init(opts) do
    backend = Keyword.get(opts, :backend, StorageBackend.default())
    schedule_cleanup()
    {:ok, %{sessions: %{}, backend: backend}}
  end

  @impl GenServer
  def handle_call({:create, filename, total_bytes, chunk_size, owner_id}, _from, state) do
    session = Session.new(filename, total_bytes, chunk_size, owner_id)
    updated = Map.put(state.sessions, session.id, session)
    {:reply, {:ok, session}, %{state | sessions: updated}}
  end

  def handle_call({:receive_chunk, session_id, chunk_index, data}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, session} ->
        {reply, updated_session} = process_chunk(session, chunk_index, data, state.backend)
        updated_sessions = Map.put(state.sessions, session_id, updated_session)
        {:reply, reply, %{state | sessions: updated_sessions}}
    end
  end

  def handle_call({:status, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      :error -> {:reply, {:error, :not_found}, state}
      {:ok, s} -> {:reply, {:ok, Session.status_map(s)}, state}
    end
  end

  def handle_call({:cancel, session_id}, _from, state) do
    case Map.pop(state.sessions, session_id) do
      {nil, _} -> {:reply, {:error, :not_found}, state}
      {session, rest} ->
        StorageBackend.delete_session(state.backend, session.id)
        {:reply, :ok, %{state | sessions: rest}}
    end
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)
    cutoff = now - @session_ttl_seconds

    {active, expired} =
      Map.split_with(state.sessions, fn {_id, s} -> s.created_at >= cutoff end)

    Enum.each(expired, fn {id, _} ->
      StorageBackend.delete_session(state.backend, id)
    end)

    schedule_cleanup()
    {:noreply, %{state | sessions: active}}
  end

  defp process_chunk(session, chunk_index, data, backend) do
    if chunk_index in session.received_chunks do
      {{:ok, :pending}, session}
    else
      StorageBackend.store_chunk(backend, session.id, chunk_index, data)
      updated = Session.record_chunk(session, chunk_index)

      if Session.complete?(updated) do
        {{:ok, :complete}, %{updated | status: :complete}}
      else
        {{:ok, :pending}, updated}
      end
    end
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)
end

defmodule Uploads.ResumableSession.Session do
  @moduledoc false

  @enforce_keys [:id, :filename, :total_bytes, :chunk_size, :total_chunks, :created_at]
  defstruct [
    :id, :filename, :total_bytes, :chunk_size, :total_chunks, :owner_id, :created_at,
    received_chunks: MapSet.new(), status: :pending
  ]

  @type t :: %__MODULE__{}

  @spec new(String.t(), pos_integer(), pos_integer(), String.t() | nil) :: t()
  def new(filename, total_bytes, chunk_size, owner_id) do
    total_chunks = ceil(total_bytes / chunk_size)
    %__MODULE__{
      id: generate_id(),
      filename: filename,
      total_bytes: total_bytes,
      chunk_size: chunk_size,
      total_chunks: total_chunks,
      owner_id: owner_id,
      created_at: System.system_time(:second)
    }
  end

  @spec record_chunk(t(), non_neg_integer()) :: t()
  def record_chunk(session, index) do
    %{session | received_chunks: MapSet.put(session.received_chunks, index)}
  end

  @spec complete?(t()) :: boolean()
  def complete?(session) do
    MapSet.size(session.received_chunks) >= session.total_chunks
  end

  @spec status_map(t()) :: map()
  def status_map(session) do
    %{
      id: session.id,
      filename: session.filename,
      total_chunks: session.total_chunks,
      received_chunks: MapSet.to_list(session.received_chunks),
      status: session.status
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
```
