```elixir
defmodule Assets.Uploader do
  @moduledoc """
  Manages asset uploads through a pluggable storage backend.

  Validates file type and size limits before delegating to the storage adapter.
  Adapter configuration is passed per-call, enabling per-tenant bucket routing.
  """

  alias Assets.Uploader.{Config, FileValidator, StorageAdapter, AssetRecord}

  @doc """
  Uploads a file binary to the configured storage backend.

  Returns `{:ok, asset_record}` with the stored key and public URL, or an error
  if validation fails or the upload is rejected by the backend.
  """
  @spec upload(binary(), String.t(), Config.t()) ::
          {:ok, AssetRecord.t()} | {:error, String.t()}
  def upload(binary, original_filename, %Config{} = config)
      when is_binary(binary) and is_binary(original_filename) do
    with {:ok, detected_type} <- FileValidator.detect_type(binary, original_filename),
         :ok <- FileValidator.check_size(binary, config.max_size_bytes),
         :ok <- FileValidator.check_allowed_type(detected_type, config.allowed_types),
         storage_key = generate_storage_key(original_filename),
         {:ok, url} <- StorageAdapter.put(config.adapter, storage_key, binary, detected_type),
         {:ok, record} <- AssetRecord.build(storage_key, url, original_filename, detected_type, byte_size(binary)) do
      {:ok, record}
    end
  end

  def upload(_, _, _), do: {:error, "invalid upload arguments"}

  @doc """
  Deletes an asset from the storage backend by its storage key.
  """
  @spec delete(String.t(), Config.t()) :: :ok | {:error, String.t()}
  def delete(storage_key, %Config{} = config) when is_binary(storage_key) do
    StorageAdapter.delete(config.adapter, storage_key)
  end

  def delete(_, _), do: {:error, "invalid storage key"}

  @doc """
  Returns a presigned URL for direct browser uploads, bypassing the server.
  """
  @spec presign_url(String.t(), String.t(), Config.t()) ::
          {:ok, %{upload_url: String.t(), storage_key: String.t()}} | {:error, String.t()}
  def presign_url(original_filename, content_type, %Config{} = config)
      when is_binary(original_filename) and is_binary(content_type) do
    with :ok <- FileValidator.check_allowed_type(content_type, config.allowed_types) do
      key = generate_storage_key(original_filename)

      case StorageAdapter.presign(config.adapter, key, content_type, config.presign_expires_seconds) do
        {:ok, url} -> {:ok, %{upload_url: url, storage_key: key}}
        error -> error
      end
    end
  end

  def presign_url(_, _, _), do: {:error, "invalid presign arguments"}

  defp generate_storage_key(filename) do
    ext = Path.extname(filename)
    unique = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    "uploads/#{unique}#{ext}"
  end
end

defmodule Assets.Uploader.Config do
  @moduledoc "Per-call upload configuration including backend adapter and limits."

  @enforce_keys [:adapter]
  defstruct [
    :adapter,
    max_size_bytes: 10 * 1024 * 1024,
    allowed_types: ["image/jpeg", "image/png", "image/webp", "application/pdf"],
    presign_expires_seconds: 900
  ]

  @type t :: %__MODULE__{
          adapter: module(),
          max_size_bytes: pos_integer(),
          allowed_types: [String.t()],
          presign_expires_seconds: pos_integer()
        }
end

defmodule Assets.Uploader.FileValidator do
  @moduledoc false

  @spec detect_type(binary(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def detect_type(<<0xFF, 0xD8, 0xFF, _::binary>>, _), do: {:ok, "image/jpeg"}
  def detect_type(<<0x89, 0x50, 0x4E, 0x47, _::binary>>, _), do: {:ok, "image/png"}
  def detect_type(<<"RIFF", _::32, "WEBP", _::binary>>, _), do: {:ok, "image/webp"}
  def detect_type(<<"%PDF", _::binary>>, _), do: {:ok, "application/pdf"}
  def detect_type(_, filename), do: {:error, "unsupported file type for #{filename}"}

  @spec check_size(binary(), pos_integer()) :: :ok | {:error, String.t()}
  def check_size(binary, max) when byte_size(binary) <= max, do: :ok
  def check_size(_, max), do: {:error, "file exceeds maximum size of #{div(max, 1024)} KB"}

  @spec check_allowed_type(String.t(), [String.t()]) :: :ok | {:error, String.t()}
  def check_allowed_type(type, allowed) do
    if type in allowed, do: :ok, else: {:error, "file type #{type} is not permitted"}
  end
end

defmodule Assets.Uploader.AssetRecord do
  @moduledoc false

  @enforce_keys [:storage_key, :url, :original_filename, :content_type, :size_bytes]
  defstruct [:storage_key, :url, :original_filename, :content_type, :size_bytes, :created_at]

  @type t :: %__MODULE__{}

  @spec build(String.t(), String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, t()} | {:error, String.t()}
  def build(key, url, filename, type, size)
      when is_binary(key) and is_binary(url) and is_binary(filename) and is_binary(type) and is_integer(size) do
    {:ok, %__MODULE__{storage_key: key, url: url, original_filename: filename,
                      content_type: type, size_bytes: size, created_at: DateTime.utc_now()}}
  end

  def build(_, _, _, _, _), do: {:error, "failed to build asset record"}
end
```
