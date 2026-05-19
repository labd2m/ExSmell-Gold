```elixir
defmodule UploadProcessor do
  use GenServer

  @moduledoc """
  Manages chunked file upload: tracks received parts, validates integrity,
  assembles the final file, and runs post-processing hooks.
  """

  @max_chunk_size_bytes 5 * 1024 * 1024
  @upload_timeout_ms 30 * 60 * 1_000

  defstruct [
    :upload_id,
    :user_id,
    :filename,
    :content_type,
    :expected_size,
    :expected_checksum,
    :storage_path,
    :status,
    received_chunks: [],
    bytes_received: 0
  ]

  def start(%{upload_id: id} = attrs) do
    GenServer.start(__MODULE__, attrs, name: via(id))
  end

  def receive_chunk(upload_id, chunk_index, chunk_data) do
    GenServer.call(via(upload_id), {:chunk, chunk_index, chunk_data}, 30_000)
  end

  def finalize(upload_id) do
    GenServer.call(via(upload_id), :finalize, 60_000)
  end

  def abort(upload_id) do
    GenServer.call(via(upload_id), :abort)
  end

  def progress(upload_id) do
    GenServer.call(via(upload_id), :progress)
  end

  defp via(id), do: {:via, Registry, {UploadRegistry, id}}

  ## Callbacks

  @impl true
  def init(%{upload_id: id, user_id: uid, filename: fname, content_type: ct, expected_size: size, expected_checksum: checksum}) do
    storage_path = "/uploads/#{uid}/#{id}/#{fname}"

    state = %__MODULE__{
      upload_id: id,
      user_id: uid,
      filename: fname,
      content_type: ct,
      expected_size: size,
      expected_checksum: checksum,
      storage_path: storage_path,
      status: :in_progress
    }

    Process.send_after(self(), :timeout, @upload_timeout_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:chunk, index, data}, _from, %{status: :in_progress} = state) do
    chunk_size = byte_size(data)

    if chunk_size > @max_chunk_size_bytes do
      {:reply, {:error, :chunk_too_large}, state}
    else
      chunk = %{index: index, size: chunk_size, checksum: :crypto.hash(:md5, data)}
      updated = %{state |
        received_chunks: [chunk | state.received_chunks],
        bytes_received: state.bytes_received + chunk_size
      }

      {:reply, {:ok, updated.bytes_received}, updated}
    end
  end

  def handle_call({:chunk, _index, _data}, _from, state) do
    {:reply, {:error, {:upload_not_in_progress, state.status}}, state}
  end

  def handle_call(:finalize, _from, %{status: :in_progress} = state) do
    sorted_chunks = Enum.sort_by(state.received_chunks, & &1.index)

    actual_checksum = compute_combined_checksum(sorted_chunks)

    if actual_checksum == state.expected_checksum do
      assemble_file(state.storage_path, sorted_chunks)
      trigger_post_processing(state)
      {:reply, {:ok, state.storage_path}, %{state | status: :completed}}
    else
      {:reply, {:error, :checksum_mismatch}, %{state | status: :failed}}
    end
  end

  def handle_call(:finalize, _from, state) do
    {:reply, {:error, {:cannot_finalize, state.status}}, state}
  end

  def handle_call(:abort, _from, state) do
    cleanup_partial(state.storage_path)
    {:reply, :ok, %{state | status: :aborted}}
  end

  def handle_call(:progress, _from, state) do
    percent = if state.expected_size > 0, do: state.bytes_received / state.expected_size * 100, else: 0

    {:reply, %{
      upload_id: state.upload_id,
      status: state.status,
      bytes_received: state.bytes_received,
      expected_size: state.expected_size,
      percent: Float.round(percent, 2),
      chunks: length(state.received_chunks)
    }, state}
  end

  @impl true
  def handle_info(:timeout, %{status: :in_progress} = state) do
    cleanup_partial(state.storage_path)
    {:stop, :normal, %{state | status: :timed_out}}
  end

  def handle_info(:timeout, state), do: {:noreply, state}

  defp compute_combined_checksum(chunks) do
    chunks
    |> Enum.map(& &1.checksum)
    |> Enum.join()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp assemble_file(_path, _chunks), do: :ok
  defp cleanup_partial(_path), do: :ok

  defp trigger_post_processing(%{content_type: "image/" <> _} = state) do
    IO.inspect(state.upload_id, label: "[UploadProcessor] Queuing image processing")
  end

  defp trigger_post_processing(_state), do: :ok
end

defmodule UploadService do
  @moduledoc "Initiates and manages file upload sessions."

  def begin(upload_id, attrs) do
    case UploadProcessor.start(Map.put(attrs, :upload_id, upload_id)) do
      {:ok, _pid} -> {:ok, upload_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def chunk(upload_id, index, data) do
    UploadProcessor.receive_chunk(upload_id, index, data)
  end

  def complete(upload_id) do
    UploadProcessor.finalize(upload_id)
  end
end
```
