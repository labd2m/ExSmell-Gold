```elixir
defmodule Media.UploadRequest do
  @moduledoc """
  Represents a validated and sanitized upload request before processing.
  """

  @type t :: %__MODULE__{
          filename: String.t(),
          content_type: String.t(),
          byte_size: pos_integer(),
          data: binary()
        }

  defstruct [:filename, :content_type, :byte_size, :data]
end

defmodule Media.Processor do
  alias Media.UploadRequest

  @moduledoc """
  Validates, sanitizes, and stores uploaded media files.
  Delegates storage to a configurable backend module passed at call time.
  """

  @allowed_content_types ~w(image/jpeg image/png image/webp application/pdf)
  @max_byte_size 10 * 1024 * 1024

  @type upload_result :: %{key: String.t(), url: String.t(), byte_size: pos_integer()}

  @spec process(map(), module()) ::
          {:ok, upload_result()} | {:error, :unsupported_type | :too_large | term()}
  def process(raw_upload, storage_backend)
      when is_map(raw_upload) and is_atom(storage_backend) do
    with {:ok, request} <- build_request(raw_upload),
         :ok <- validate_type(request),
         :ok <- validate_size(request),
         {:ok, result} <- storage_backend.store(request) do
      {:ok, result}
    end
  end

  @spec build_request(map()) :: {:ok, UploadRequest.t()} | {:error, :invalid_upload}
  defp build_request(%{filename: filename, content_type: ct, data: data})
       when is_binary(filename) and is_binary(ct) and is_binary(data) do
    request = %UploadRequest{
      filename: sanitize_filename(filename),
      content_type: ct,
      byte_size: byte_size(data),
      data: data
    }

    {:ok, request}
  end

  defp build_request(_raw), do: {:error, :invalid_upload}

  defp validate_type(%UploadRequest{content_type: ct}) do
    if ct in @allowed_content_types do
      :ok
    else
      {:error, :unsupported_type}
    end
  end

  defp validate_size(%UploadRequest{byte_size: size}) do
    if size <= @max_byte_size do
      :ok
    else
      {:error, :too_large}
    end
  end

  defp sanitize_filename(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[^\w\.\-]/, "_")
  end
end

defmodule Media.S3Backend do
  alias Media.UploadRequest

  @moduledoc """
  Uploads processed media files to an S3-compatible object store.
  Requires a runtime configuration map with credentials and bucket info.
  """

  @type config :: %{bucket: String.t(), region: String.t(), access_key: String.t(),
                    secret_key: String.t()}
  @type result :: %{key: String.t(), url: String.t(), byte_size: pos_integer()}

  @spec store(UploadRequest.t(), config()) :: {:ok, result()} | {:error, term()}
  def store(%UploadRequest{} = request, config \\ %{}) do
    key = "uploads/#{generate_key(request.filename)}"

    s3_config = [
      access_key_id: config[:access_key],
      secret_access_key: config[:secret_key],
      region: config[:region]
    ]

    case ExAws.S3.put_object(config[:bucket], key, request.data,
           content_type: request.content_type,
           acl: :private
         )
         |> ExAws.request(s3_config) do
      {:ok, _response} ->
        url = "https://#{config[:bucket]}.s3.#{config[:region]}.amazonaws.com/#{key}"
        {:ok, %{key: key, url: url, byte_size: request.byte_size}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_key(filename) do
    hash = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    ext = Path.extname(filename)
    "#{hash}#{ext}"
  end
end
```
