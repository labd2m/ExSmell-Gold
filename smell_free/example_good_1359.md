```elixir
defmodule ObjectStorage.Client do
  @moduledoc """
  An S3-compatible object storage client supporting streaming multipart uploads.
  Credentials and endpoint are accepted per-call to support multi-region and
  multi-account configurations from a single client module.
  """

  @type credentials :: %{access_key: String.t(), secret_key: String.t(), region: String.t()}
  @type upload_opts :: %{optional(:part_size_bytes) => pos_integer(), optional(:content_type) => String.t()}

  @default_part_size 8 * 1024 * 1024

  @spec put_object(String.t(), String.t(), binary(), credentials(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def put_object(bucket, key, body, %{} = credentials, opts \\ [])
      when is_binary(bucket) and is_binary(key) and is_binary(body) do
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    url = build_url(credentials, bucket, key)
    headers = sign_headers("PUT", url, body, content_type, credentials)

    case :hackney.put(url, headers, body, []) do
      {:ok, 200, _resp_headers, _ref} -> {:ok, url}
      {:ok, status, _headers, ref} -> {:error, decode_error(status, ref)}
      {:error, reason} -> {:error, {:transport_error, reason}}
    end
  end

  @spec stream_upload(String.t(), String.t(), Enumerable.t(), credentials(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def stream_upload(bucket, key, data_stream, %{} = credentials, opts \\ [])
      when is_binary(bucket) and is_binary(key) do
    part_size = Keyword.get(opts, :part_size_bytes, @default_part_size)

    with {:ok, upload_id} <- initiate_multipart(bucket, key, credentials, opts),
         {:ok, parts} <- upload_parts(bucket, key, upload_id, data_stream, part_size, credentials),
         {:ok, _} <- complete_multipart(bucket, key, upload_id, parts, credentials) do
      {:ok, build_url(credentials, bucket, key)}
    end
  end

  @spec get_object(String.t(), String.t(), credentials()) ::
          {:ok, binary()} | {:error, term()}
  def get_object(bucket, key, %{} = credentials) when is_binary(bucket) and is_binary(key) do
    url = build_url(credentials, bucket, key)
    headers = sign_headers("GET", url, "", "application/octet-stream", credentials)

    case :hackney.get(url, headers, "", []) do
      {:ok, 200, _resp_headers, ref} ->
        :hackney.body(ref)

      {:ok, 404, _headers, _ref} ->
        {:error, :not_found}

      {:ok, status, _headers, ref} ->
        {:error, decode_error(status, ref)}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  @spec delete_object(String.t(), String.t(), credentials()) :: :ok | {:error, term()}
  def delete_object(bucket, key, %{} = credentials) when is_binary(bucket) and is_binary(key) do
    url = build_url(credentials, bucket, key)
    headers = sign_headers("DELETE", url, "", "application/octet-stream", credentials)

    case :hackney.delete(url, headers, "", []) do
      {:ok, status, _, _} when status in 200..204 -> :ok
      {:ok, status, _, ref} -> {:error, decode_error(status, ref)}
      {:error, reason} -> {:error, {:transport_error, reason}}
    end
  end

  defp initiate_multipart(bucket, key, credentials, opts) do
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    url = "#{build_url(credentials, bucket, key)}?uploads"
    headers = sign_headers("POST", url, "", content_type, credentials)

    case :hackney.post(url, headers, "", []) do
      {:ok, 200, _headers, ref} ->
        {:ok, body} = :hackney.body(ref)
        extract_upload_id(body)
      {:ok, status, _headers, ref} ->
        {:error, decode_error(status, ref)}
    end
  end

  defp upload_parts(bucket, key, upload_id, stream, part_size, credentials) do
    stream
    |> Stream.chunk_every(part_size)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {chunk_data, part_number}, {:ok, parts} ->
      part_bytes = IO.iodata_to_binary(chunk_data)
      url = "#{build_url(credentials, bucket, key)}?partNumber=#{part_number}&uploadId=#{upload_id}"
      headers = sign_headers("PUT", url, part_bytes, "application/octet-stream", credentials)

      case :hackney.put(url, headers, part_bytes, []) do
        {:ok, 200, resp_headers, _ref} ->
          etag = :proplists.get_value("ETag", resp_headers, "")
          {:cont, {:ok, [{part_number, etag} | parts]}}
        {:ok, status, _, ref} ->
          {:halt, {:error, decode_error(status, ref)}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      err -> err
    end
  end

  defp complete_multipart(bucket, key, upload_id, parts, credentials) do
    url = "#{build_url(credentials, bucket, key)}?uploadId=#{upload_id}"
    body = build_complete_xml(parts)
    headers = sign_headers("POST", url, body, "application/xml", credentials)

    case :hackney.post(url, headers, body, []) do
      {:ok, 200, _headers, ref} -> {:ok, ref}
      {:ok, status, _headers, ref} -> {:error, decode_error(status, ref)}
    end
  end

  defp build_url(%{region: region}, bucket, key) do
    "https://#{bucket}.s3.#{region}.amazonaws.com/#{URI.encode(key)}"
  end

  defp sign_headers(_method, _url, _body, content_type, _credentials) do
    [{"Content-Type", content_type}]
  end

  defp extract_upload_id(xml_body) do
    case Regex.run(~r/<UploadId>(.+?)<\/UploadId>/, xml_body) do
      [_, upload_id] -> {:ok, upload_id}
      _ -> {:error, :missing_upload_id}
    end
  end

  defp build_complete_xml(parts) do
    part_xml =
      Enum.map_join(parts, "", fn {number, etag} ->
        "<Part><PartNumber>#{number}</PartNumber><ETag>#{etag}</ETag></Part>"
      end)

    "<CompleteMultipartUpload>#{part_xml}</CompleteMultipartUpload>"
  end

  defp decode_error(status, ref) do
    {:ok, body} = :hackney.body(ref)
    {:s3_error, status, body}
  end
end
```
