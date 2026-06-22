```elixir
defmodule Uploads.Processor do
  @moduledoc """
  Coordinates a multi-stage file upload pipeline: virus scan, metadata extraction,
  thumbnail generation, and storage persistence. Each stage is a discrete
  function that returns tagged results, allowing precise failure attribution.
  """

  alias Uploads.{Metadata, Storage, Scanner, Thumbnailer}

  @type upload_input :: %{
          path: String.t(),
          filename: String.t(),
          content_type: String.t(),
          owner_id: integer()
        }

  @type upload_result ::
          {:ok, Storage.stored_file()}
          | {:error, :scan_rejected, String.t()}
          | {:error, :metadata_extraction_failed}
          | {:error, :storage_failed, term()}

  @spec process(upload_input()) :: upload_result()
  def process(%{path: path, filename: filename, content_type: ct, owner_id: owner_id} = input)
      when is_binary(path) and is_binary(filename) and is_binary(ct) and is_integer(owner_id) do
    with {:ok, :clean} <- Scanner.scan(path),
         {:ok, meta} <- Metadata.extract(path, content_type: ct),
         {:ok, thumbnail_path} <- maybe_generate_thumbnail(path, ct),
         {:ok, stored} <- Storage.persist(input, meta, thumbnail_path: thumbnail_path) do
      {:ok, stored}
    else
      {:error, {:scan_rejected, reason}} -> {:error, :scan_rejected, reason}
      {:error, :metadata_extraction_failed} -> {:error, :metadata_extraction_failed}
      {:error, {:storage_error, reason}} -> {:error, :storage_failed, reason}
    end
  end

  defp maybe_generate_thumbnail(path, content_type) do
    if image_type?(content_type) do
      Thumbnailer.generate(path)
    else
      {:ok, nil}
    end
  end

  defp image_type?("image/" <> _), do: true
  defp image_type?(_), do: false
end

defmodule Uploads.Metadata do
  @moduledoc """
  Extracts file metadata such as size, MIME type, and image dimensions.
  """

  @type t :: %{
          size_bytes: non_neg_integer(),
          mime_type: String.t(),
          dimensions: {pos_integer(), pos_integer()} | nil
        }

  @spec extract(String.t(), keyword()) :: {:ok, t()} | {:error, :metadata_extraction_failed}
  def extract(path, opts \\ []) when is_binary(path) do
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    with {:ok, stat} <- File.stat(path) do
      {:ok,
       %{
         size_bytes: stat.size,
         mime_type: content_type,
         dimensions: maybe_image_dimensions(path, content_type)
       }}
    else
      {:error, _} -> {:error, :metadata_extraction_failed}
    end
  end

  defp maybe_image_dimensions(path, "image/" <> _) do
    case ExImageInfo.info(File.read!(path)) do
      {_type, w, h, _variant} -> {w, h}
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp maybe_image_dimensions(_path, _content_type), do: nil
end

defmodule Uploads.Scanner do
  @moduledoc """
  Placeholder virus-scan wrapper. Delegates to the configured scan adapter
  which can be swapped for testing or for different vendor integrations.
  """

  @spec scan(String.t()) :: {:ok, :clean} | {:error, {:scan_rejected, String.t()}}
  def scan(path) when is_binary(path) do
    adapter = Application.get_env(:uploads, :scanner_adapter, Uploads.Scanners.Noop)
    adapter.scan(path)
  end
end

defmodule Uploads.Scanners.Noop do
  @moduledoc "Scanner adapter that approves all files — intended for development use only."

  @spec scan(String.t()) :: {:ok, :clean}
  def scan(_path), do: {:ok, :clean}
end
```
