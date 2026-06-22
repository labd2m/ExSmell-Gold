**File:** `example_good_1307.md`

```elixir
defmodule Uploads.UploadRequest do
  @moduledoc "Represents a validated incoming file upload request."

  @enforce_keys [:filename, :content_type, :size_bytes, :temp_path]
  defstruct [:filename, :content_type, :size_bytes, :temp_path]

  @type t :: %__MODULE__{
          filename: String.t(),
          content_type: String.t(),
          size_bytes: pos_integer(),
          temp_path: String.t()
        }
end

defmodule Uploads.StoredFile do
  @moduledoc "Represents a successfully stored file with its resolved public location."

  @enforce_keys [:id, :filename, :content_type, :size_bytes, :storage_key, :stored_at]
  defstruct [:id, :filename, :content_type, :size_bytes, :storage_key, :stored_at]

  @type t :: %__MODULE__{
          id: String.t(),
          filename: String.t(),
          content_type: String.t(),
          size_bytes: pos_integer(),
          storage_key: String.t(),
          stored_at: DateTime.t()
        }
end

defmodule Uploads.StorageBackend do
  @moduledoc "Behaviour contract for file storage backend adapters."

  @doc "Persists a file from a local temp path to the storage backend."
  @callback store(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}

  @doc "Deletes a stored file by its storage key."
  @callback delete(String.t()) :: :ok | {:error, term()}

  @doc "Returns a URL to access the stored file."
  @callback public_url(String.t()) :: String.t()
end

defmodule Uploads.Validator do
  @moduledoc "Validates upload requests against configured content type and size policies."

  alias Uploads.UploadRequest

  @type policy :: %{
          allowed_content_types: [String.t()],
          max_size_bytes: pos_integer()
        }
  @type validation_result :: :ok | {:error, atom()}

  @spec validate(UploadRequest.t(), policy()) :: validation_result()
  def validate(%UploadRequest{} = req, policy) do
    with :ok <- check_content_type(req.content_type, policy.allowed_content_types),
         :ok <- check_file_size(req.size_bytes, policy.max_size_bytes) do
      :ok
    end
  end

  defp check_content_type(type, allowed) do
    if type in allowed, do: :ok, else: {:error, :content_type_not_allowed}
  end

  defp check_file_size(size, max) when size <= max, do: :ok
  defp check_file_size(_size, _max), do: {:error, :file_too_large}
end

defmodule Uploads do
  @moduledoc """
  Context for handling file uploads. Validates, stores, and tracks uploaded
  files through a configured storage backend.
  """

  alias Uploads.{StorageBackend, StoredFile, UploadRequest, Validator}

  @default_policy %{
    allowed_content_types: ~w(image/jpeg image/png image/webp application/pdf),
    max_size_bytes: 20 * 1024 * 1024
  }

  @spec upload(UploadRequest.t(), module(), keyword()) ::
          {:ok, StoredFile.t()} | {:error, atom()} | {:error, term()}
  def upload(%UploadRequest{} = request, backend, opts \\ []) do
    policy = Keyword.get(opts, :policy, @default_policy)
    prefix = Keyword.get(opts, :prefix, "uploads")

    with :ok <- Validator.validate(request, policy) do
      storage_key = build_storage_key(prefix, request.filename)

      case backend.store(request.temp_path, storage_key, request.content_type) do
        {:ok, _} ->
          {:ok, %StoredFile{
            id: generate_id(),
            filename: sanitize_filename(request.filename),
            content_type: request.content_type,
            size_bytes: request.size_bytes,
            storage_key: storage_key,
            stored_at: DateTime.utc_now()
          }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec delete(StoredFile.t(), module()) :: :ok | {:error, term()}
  def delete(%StoredFile{storage_key: key}, backend) do
    backend.delete(key)
  end

  @spec public_url(StoredFile.t(), module()) :: String.t()
  def public_url(%StoredFile{storage_key: key}, backend) do
    backend.public_url(key)
  end

  defp build_storage_key(prefix, filename) do
    id = generate_id()
    ext = Path.extname(filename)
    "#{prefix}/#{id}#{ext}"
  end

  defp sanitize_filename(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[^\w.\-]/, "_")
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
```
