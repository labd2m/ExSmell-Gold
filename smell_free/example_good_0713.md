```elixir
defmodule Platform.ChunkedUpload do
  @moduledoc """
  A GenServer that manages the lifecycle of a chunked (multipart) file upload.

  Clients upload individual parts identified by `{upload_id, chunk_index}`.
  Once all expected chunks arrive, the assembler concatenates them in order,
  writes the complete file, and notifies the caller via message or callback.
  """

  use GenServer, restart: :transient

  require Logger

  @type upload_id :: String.t()
  @type chunk_index :: non_neg_integer()
  @type upload_opts :: [
          total_chunks: pos_integer(),
          filename: String.t(),
          on_complete: (String.t() -> :ok)
        ]

  @chunk_timeout_ms :timer.minutes(30)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    upload_id = Keyword.fetch!(opts, :upload_id)
    GenServer.start_link(__MODULE__, opts, name: via(upload_id))
  end

  @doc """
  Submits a chunk for the given upload. Returns `:ok` or
  `{:error, :upload_not_found | :chunk_already_received}`.
  """
  @spec submit_chunk(upload_id(), chunk_index(), binary()) ::
          :ok | {:error, :chunk_already_received}
  def submit_chunk(upload_id, index, data)
      when is_binary(upload_id) and is_integer(index) and is_binary(data) do
    GenServer.call(via(upload_id), {:chunk, index, data})
  end

  @doc "Returns the current upload status."
  @spec status(upload_id()) :: {:ok, map()} | {:error, :not_found}
  def status(upload_id) when is_binary(upload_id) do
    case Registry.lookup(Platform.UploadRegistry, upload_id) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :status)}
      [] -> {:error, :not_found}
    end
  end

  @impl GenServer
  def init(opts) do
    state = %{
      upload_id: Keyword.fetch!(opts, :upload_id),
      total_chunks: Keyword.fetch!(opts, :total_chunks),
      filename: Keyword.get(opts, :filename, "upload"),
      on_complete: Keyword.get(opts, :on_complete),
      chunks: %{},
      started_at: DateTime.utc_now()
    }

    Process.send_after(self(), :timeout, @chunk_timeout_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:chunk, index, data}, _from, %{chunks: chunks} = state) do
    if Map.has_key?(chunks, index) do
      {:reply, {:error, :chunk_already_received}, state}
    else
      new_chunks = Map.put(chunks, index, data)
      new_state = %{state | chunks: new_chunks}

      if map_size(new_chunks) >= state.total_chunks do
        {:reply, :ok, new_state, {:continue, :assemble}}
      else
        {:reply, :ok, new_state}
      end
    end
  end

  @impl GenServer
  def handle_call(:status, _from, %{chunks: chunks, total_chunks: total} = state) do
    status = %{
      upload_id: state.upload_id,
      received: map_size(chunks),
      total: total,
      complete: map_size(chunks) >= total,
      started_at: state.started_at
    }

    {:reply, status, state}
  end

  @impl GenServer
  def handle_continue(:assemble, state) do
    assembled = assemble_chunks(state.chunks, state.total_chunks)
    path = write_to_temp(assembled, state.filename)
    Logger.info("[ChunkedUpload] Assembly complete", upload_id: state.upload_id, path: path)
    if state.on_complete, do: state.on_complete.(path)
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    Logger.warning("[ChunkedUpload] Upload timed out", upload_id: state.upload_id)
    {:stop, {:shutdown, :timeout}, state}
  end

  defp assemble_chunks(chunks, total) do
    0..(total - 1)
    |> Enum.map(&Map.fetch!(chunks, &1))
    |> IO.iodata_to_binary()
  end

  defp write_to_temp(data, filename) do
    dir = System.tmp_dir!()
    path = Path.join(dir, "upload_#{:erlang.unique_integer([:positive])}_#{filename}")
    File.write!(path, data)
    path
  end

  defp via(upload_id) do
    {:via, Registry, {Platform.UploadRegistry, upload_id}}
  end
end
```
