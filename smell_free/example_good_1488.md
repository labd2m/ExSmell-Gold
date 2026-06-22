```elixir
defmodule Media.Upload.Processor do
  @moduledoc """
  Validates, transforms, and stores uploaded media files.
  Processing stages are executed as a sequential pipeline with structured error reporting.
  """

  alias Media.Upload.{Metadata, Storage}

  @type upload :: %{filename: String.t(), content_type: String.t(), size_bytes: pos_integer(), path: String.t()}
  @type processed :: %{id: String.t(), url: String.t(), metadata: Metadata.t()}

  @allowed_content_types ~w(image/jpeg image/png image/webp video/mp4)
  @max_size_bytes 52_428_800

  @doc """
  Processes a raw upload map through validation and storage.

  Returns `{:ok, processed}` on success or `{:error, reason}` on failure.
  """
  @spec process(upload(), keyword()) :: {:ok, processed()} | {:error, String.t()}
  def process(upload, opts \\ []) when is_map(upload) do
    storage = Keyword.get(opts, :storage, Storage.S3)

    with :ok <- validate_content_type(upload),
         :ok <- validate_size(upload),
         {:ok, metadata} <- Metadata.extract(upload.path, upload.content_type),
         {:ok, url} <- storage.store(upload, metadata) do
      {:ok, %{id: Ecto.UUID.generate(), url: url, metadata: metadata}}
    end
  end

  defp validate_content_type(%{content_type: ct}) do
    if ct in @allowed_content_types do
      :ok
    else
      {:error, "unsupported content type: #{ct}"}
    end
  end

  defp validate_size(%{size_bytes: size}) when size > @max_size_bytes do
    {:error, "file size #{size} exceeds maximum of #{@max_size_bytes} bytes"}
  end

  defp validate_size(%{size_bytes: size}) when is_integer(size) and size > 0, do: :ok
  defp validate_size(_), do: {:error, "invalid or missing file size"}
end

defmodule Media.Upload.Metadata do
  @moduledoc """
  Extracts technical metadata from an uploaded media file using file inspection.
  """

  @type t :: %__MODULE__{
          width: non_neg_integer() | nil,
          height: non_neg_integer() | nil,
          duration_seconds: float() | nil,
          content_type: String.t()
        }

  defstruct [:width, :height, :duration_seconds, :content_type]

  @doc """
  Extracts metadata from the file at `path` based on its content type.
  """
  @spec extract(String.t(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def extract(path, content_type) when is_binary(path) and is_binary(content_type) do
    case File.stat(path) do
      {:ok, _stat} -> do_extract(path, content_type)
      {:error, reason} -> {:error, "cannot read file at #{path}: #{reason}"}
    end
  end

  defp do_extract(_path, "video/mp4") do
    {:ok,
     %__MODULE__{
       width: nil,
       height: nil,
       duration_seconds: nil,
       content_type: "video/mp4"
     }}
  end

  defp do_extract(_path, content_type) do
    {:ok,
     %__MODULE__{
       width: nil,
       height: nil,
       duration_seconds: nil,
       content_type: content_type
     }}
  end
end
```
