```elixir
defmodule Uploads.FileSpec do
  @moduledoc false

  @type t :: %__MODULE__{
          max_size_bytes: pos_integer(),
          allowed_content_types: [String.t()],
          destination_prefix: String.t()
        }

  defstruct [
    max_size_bytes: 10 * 1_024 * 1_024,
    allowed_content_types: ["image/jpeg", "image/png", "image/webp"],
    destination_prefix: "uploads"
  ]
end

defmodule Uploads.UploadedFile do
  @moduledoc false

  @type t :: %__MODULE__{
          key: String.t(),
          original_filename: String.t(),
          content_type: String.t(),
          size_bytes: non_neg_integer(),
          url: String.t()
        }

  defstruct [:key, :original_filename, :content_type, :size_bytes, :url]
end

defmodule Uploads.Pipeline do
  @moduledoc """
  Validates and stores user-submitted file uploads.

  The pipeline enforces content-type and size constraints before
  delegating storage to a configured backend. Each stage produces
  a typed result, and the first failure short-circuits the pipeline
  without side effects on later stages.
  """

  alias Uploads.{FileSpec, UploadedFile}

  @type raw_upload :: %{
          required(:filename) => String.t(),
          required(:content_type) => String.t(),
          required(:path) => String.t(),
          required(:size) => non_neg_integer()
        }

  @type upload_error ::
          {:error, :content_type_not_allowed}
          | {:error, :file_too_large}
          | {:error, :empty_file}
          | {:error, {:storage_failed, term()}}

  @spec process(raw_upload(), FileSpec.t(), module()) ::
          {:ok, UploadedFile.t()} | upload_error()
  def process(%{} = upload, %FileSpec{} = spec, storage_backend) do
    with :ok <- validate_content_type(upload.content_type, spec.allowed_content_types),
         :ok <- validate_size(upload.size, spec.max_size_bytes),
         :ok <- validate_non_empty(upload.size),
         key <- build_key(spec.destination_prefix, upload.filename),
         {:ok, url} <- storage_backend.store(key, upload.path, upload.content_type) do
      result = %UploadedFile{
        key: key,
        original_filename: upload.filename,
        content_type: upload.content_type,
        size_bytes: upload.size,
        url: url
      }

      {:ok, result}
    end
  end

  defp validate_content_type(content_type, allowed) do
    if content_type in allowed do
      :ok
    else
      {:error, :content_type_not_allowed}
    end
  end

  defp validate_size(size, max) when size > max, do: {:error, :file_too_large}
  defp validate_size(_size, _max), do: :ok

  defp validate_non_empty(0), do: {:error, :empty_file}
  defp validate_non_empty(_size), do: :ok

  defp build_key(prefix, filename) do
    ext = filename |> Path.extname() |> String.downcase()
    random = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    date = Date.utc_today() |> Date.to_string()
    "#{prefix}/#{date}/#{random}#{ext}"
  end
end

defmodule Uploads.LocalStorageBackend do
  @moduledoc """
  A local-filesystem storage backend for use in development and tests.
  """

  @storage_root "priv/uploads"

  @spec store(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def store(key, source_path, _content_type) when is_binary(key) and is_binary(source_path) do
    destination = Path.join(@storage_root, key)

    with :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.cp(source_path, destination) do
      {:ok, "/uploads/#{key}"}
    else
      {:error, reason} -> {:error, {:storage_failed, reason}}
    end
  end
end
```
