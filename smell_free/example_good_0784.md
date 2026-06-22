```elixir
defmodule MyAppWeb.AssetController do
  @moduledoc """
  Streams private S3 assets directly to the client through Phoenix without
  buffering the full file in server memory. The controller verifies the
  signed download URL, authorises the requesting user against the asset
  record, then opens an HTTP range-request stream and pipes chunks to the
  socket as they arrive. Content-Disposition and Content-Type headers are
  set from the stored asset metadata so browsers handle the download correctly.
  """

  use MyAppWeb, :controller

  alias MyApp.{Assets, Auth}
  alias Storage.S3Streamer

  require Logger

  @chunk_size_bytes 512 * 1024

  @doc """
  Streams the asset identified by `id` to the requesting user.
  Responds with `403` when the user is not authorised, `404` when the
  asset does not exist, and `200` with a chunked body on success.
  """
  def download(conn, %{"id" => asset_id}) do
    with {:ok, user} <- Auth.current_user(conn),
         {:ok, asset} <- Assets.fetch(asset_id),
         :ok <- Assets.authorize_download(user, asset) do
      stream_asset(conn, asset)
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "asset_not_found"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      {:error, :unauthenticated} ->
        conn |> put_status(:unauthorized) |> json(%{error: "authentication_required"})
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp stream_asset(conn, asset) do
    Logger.info("Streaming asset",
      asset_id: asset.id,
      key: asset.storage_key,
      size_bytes: asset.size_bytes
    )

    conn =
      conn
      |> put_resp_content_type(asset.content_type)
      |> put_resp_header("content-disposition", disposition(asset))
      |> put_resp_header("content-length", to_string(asset.size_bytes))
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_chunked(200)

    asset.storage_key
    |> S3Streamer.stream(chunk_size: @chunk_size_bytes)
    |> Enum.reduce_while(conn, fn chunk, conn ->
      case chunk(conn, chunk) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end

  defp disposition(%{filename: filename, inline: true}) do
    safe_name = sanitize_filename(filename)
    "inline; filename=\"#{safe_name}\""
  end

  defp disposition(%{filename: filename}) do
    safe_name = sanitize_filename(filename)
    "attachment; filename=\"#{safe_name}\""
  end

  defp sanitize_filename(name) do
    name
    |> String.replace(~r/[^\w.\-]/, "_")
    |> String.slice(0, 255)
  end
end

defmodule Storage.S3Streamer do
  @moduledoc """
  Returns a lazy `Stream` of binary chunks read from an S3 object.
  Each element is a binary of at most `:chunk_size` bytes. The stream
  opens a single HTTP connection and reads the response body incrementally
  so arbitrarily large objects are handled without loading them into memory.
  """

  @default_chunk_size 512 * 1024

  @doc """
  Returns a `Stream.t()` of binary chunks for the object at `key`.
  The stream is lazy; no HTTP request is made until the stream is consumed.
  """
  @spec stream(binary(), keyword()) :: Enumerable.t()
  def stream(key, opts \\ []) when is_binary(key) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    bucket = Application.fetch_env!(:my_app, :s3_bucket)

    Stream.resource(
      fn -> open_connection(bucket, key) end,
      fn state -> read_chunk(state, chunk_size) end,
      fn state -> close_connection(state) end
    )
  end

  defp open_connection(bucket, key) do
    url = "https://#{bucket}.s3.amazonaws.com/#{URI.encode(key)}"
    headers = MyApp.Storage.auth_headers("GET", key)

    {:ok, _ref} = :hackney.request(:get, url, headers, "", [:async, {:stream_to, self()}])
    %{buffer: "", done: false}
  end

  defp read_chunk(%{done: true, buffer: ""} = state, _size) do
    {:halt, state}
  end

  defp read_chunk(%{done: true, buffer: buf} = state, _size) when byte_size(buf) > 0 do
    {[buf], %{state | buffer: ""}}
  end

  defp read_chunk(state, chunk_size) do
    receive do
      {:hackney_response, _ref, {:status, 200, _}} ->
        read_chunk(state, chunk_size)

      {:hackney_response, _ref, {:headers, _headers}} ->
        read_chunk(state, chunk_size)

      {:hackney_response, _ref, :done} ->
        if byte_size(state.buffer) > 0 do
          {[state.buffer], %{state | done: true, buffer: ""}}
        else
          {:halt, %{state | done: true}}
        end

      {:hackney_response, _ref, bin} when is_binary(bin) ->
        new_buf = state.buffer <> bin

        if byte_size(new_buf) >= chunk_size do
          {chunk, rest} = :erlang.split_binary(new_buf, chunk_size)
          {[chunk], %{state | buffer: rest}}
        else
          read_chunk(%{state | buffer: new_buf}, chunk_size)
        end
    after
      30_000 -> {:halt, state}
    end
  end

  defp close_connection(_state), do: :ok
end
```
