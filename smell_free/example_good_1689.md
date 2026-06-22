```elixir
defmodule Uploads.ChunkedSession do
  @moduledoc """
  Manages a resumable chunked file upload session. The client uploads
  fixed-size chunks which are assembled in order after all parts arrive.
  Sessions expire if not completed within a configurable TTL.
  """

  use GenServer

  alias Uploads.{SessionStore, ChunkStore, FileAssembler}

  @default_chunk_size 5_242_880
  @session_ttl_seconds 3_600

  @type session_id :: String.t()
  @type chunk_index :: non_neg_integer()

  @type session :: %{
          id: session_id(),
          filename: String.t(),
          total_size: pos_integer(),
          total_chunks: pos_integer(),
          received: MapSet.t(),
          owner_id: String.t(),
          content_type: String.t(),
          expires_at: DateTime.t()
        }

  @spec start_session(String.t(), String.t(), pos_integer(), String.t()) ::
          {:ok, %{session_id: session_id(), chunk_size: pos_integer(), total_chunks: pos_integer()}}
          | {:error, atom()}
  def start_session(owner_id, filename, total_size, content_type)
      when is_binary(owner_id) and total_size > 0 do
    chunk_size = @default_chunk_size
    total_chunks = ceil(total_size / chunk_size)
    session_id = generate_session_id()
    expires_at = DateTime.add(DateTime.utc_now(), @session_ttl_seconds, :second)

    session = %{
      id: session_id,
      filename: filename,
      total_size: total_size,
      total_chunks: total_chunks,
      received: MapSet.new(),
      owner_id: owner_id,
      content_type: content_type,
      expires_at: expires_at
    }

    case SessionStore.put(session_id, session) do
      :ok -> {:ok, %{session_id: session_id, chunk_size: chunk_size, total_chunks: total_chunks}}
      error -> error
    end
  end

  @spec upload_chunk(session_id(), chunk_index(), binary()) ::
          {:ok, :received} | {:ok, :complete, String.t()} | {:error, atom()}
  def upload_chunk(session_id, index, data)
      when is_binary(session_id) and is_integer(index) and is_binary(data) do
    with {:ok, session} <- fetch_live_session(session_id),
         :ok <- validate_chunk_index(session, index),
         :ok <- store_chunk(session_id, index, data) do
      updated = %{session | received: MapSet.put(session.received, index)}
      SessionStore.put(session_id, updated)

      if all_chunks_received?(updated) do
        case FileAssembler.assemble(session_id, updated) do
          {:ok, storage_key} ->
            SessionStore.delete(session_id)
            {:ok, :complete, storage_key}
          {:error, reason} ->
            {:error, reason}
        end
      else
        {:ok, :received}
      end
    end
  end

  @spec session_status(session_id()) ::
          {:ok, %{received: non_neg_integer(), total: pos_integer(), percent: float()}}
          | {:error, :not_found | :expired}
  def session_status(session_id) when is_binary(session_id) do
    with {:ok, session} <- fetch_live_session(session_id) do
      received = MapSet.size(session.received)
      percent = received / session.total_chunks * 100

      {:ok, %{received: received, total: session.total_chunks, percent: Float.round(percent, 1)}}
    end
  end

  @spec abort(session_id()) :: :ok
  def abort(session_id) when is_binary(session_id) do
    ChunkStore.delete_all(session_id)
    SessionStore.delete(session_id)
    :ok
  end

  @spec fetch_live_session(session_id()) :: {:ok, session()} | {:error, :not_found | :expired}
  defp fetch_live_session(session_id) do
    case SessionStore.get(session_id) do
      {:ok, session} ->
        if DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt do
          {:ok, session}
        else
          SessionStore.delete(session_id)
          {:error, :expired}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @spec validate_chunk_index(session(), chunk_index()) :: :ok | {:error, :invalid_chunk_index}
  defp validate_chunk_index(session, index) do
    if index >= 0 and index < session.total_chunks do
      :ok
    else
      {:error, :invalid_chunk_index}
    end
  end

  @spec store_chunk(session_id(), chunk_index(), binary()) :: :ok | {:error, atom()}
  defp store_chunk(session_id, index, data) do
    ChunkStore.put(session_id, index, data)
  end

  @spec all_chunks_received?(session()) :: boolean()
  defp all_chunks_received?(session) do
    MapSet.size(session.received) == session.total_chunks
  end

  @spec generate_session_id() :: session_id()
  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
```
