# File: `example_good_249.md`

```elixir
defmodule Media.MetadataExtractor do
  @moduledoc """
  Extracts and normalises metadata from uploaded media files, delegating
  to format-specific parsers based on the detected MIME type.

  Metadata is returned as a uniform map regardless of the source format
  so callers do not branch on file type when storing or displaying results.
  """

  @type mime_type :: String.t()
  @type file_path :: String.t()

  @type media_metadata :: %{
          mime_type: mime_type(),
          file_size_bytes: non_neg_integer(),
          width_px: pos_integer() | nil,
          height_px: pos_integer() | nil,
          duration_seconds: float() | nil,
          title: String.t() | nil,
          author: String.t() | nil,
          created_at: DateTime.t() | nil,
          extra: map()
        }

  @type extract_result :: {:ok, media_metadata()} | {:error, atom()}

  @doc """
  Extracts metadata from the file at `path`.

  The MIME type is detected from the file's magic bytes rather than
  the filename extension. Returns `{:ok, metadata}` on success or
  `{:error, reason}` if the file cannot be read or is an unsupported format.
  """
  @spec extract(file_path()) :: extract_result()
  def extract(path) when is_binary(path) do
    with {:ok, bytes} <- read_header_bytes(path),
         {:ok, mime_type} <- detect_mime_type(bytes),
         {:ok, file_size} <- file_size(path),
         {:ok, raw_meta} <- parse_by_type(path, mime_type) do
      metadata = normalise(raw_meta, mime_type, file_size)
      {:ok, metadata}
    end
  end

  @doc """
  Returns the MIME type of the file at `path` based on magic bytes.

  Returns `{:ok, mime_type}` or `{:error, :unrecognised_format}`.
  """
  @spec detect_mime_type_for(file_path()) :: {:ok, mime_type()} | {:error, :unrecognised_format}
  def detect_mime_type_for(path) when is_binary(path) do
    with {:ok, bytes} <- read_header_bytes(path) do
      detect_mime_type(bytes)
    end
  end

  defp read_header_bytes(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        bytes = IO.binread(file, 16)
        File.close(file)
        if is_binary(bytes), do: {:ok, bytes}, else: {:error, :unreadable}

      {:error, _} ->
        {:error, :file_not_found}
    end
  end

  defp detect_mime_type(<<0x89, 0x50, 0x4E, 0x47, _::binary>>), do: {:ok, "image/png"}
  defp detect_mime_type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  defp detect_mime_type(<<"GIF87a", _::binary>>), do: {:ok, "image/gif"}
  defp detect_mime_type(<<"GIF89a", _::binary>>), do: {:ok, "image/gif"}
  defp detect_mime_type(<<0x52, 0x49, 0x46, 0x46, _::32, 0x57, 0x41, 0x56, 0x45, _::binary>>), do: {:ok, "audio/wav"}
  defp detect_mime_type(<<"ID3", _::binary>>), do: {:ok, "audio/mpeg"}
  defp detect_mime_type(<<0x00, 0x00, 0x00, _, 0x66, 0x74, 0x79, 0x70, _::binary>>), do: {:ok, "video/mp4"}
  defp detect_mime_type(<<0x25, 0x50, 0x44, 0x46, _::binary>>), do: {:ok, "application/pdf"}
  defp detect_mime_type(_), do: {:error, :unrecognised_format}

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> {:ok, size}
      {:error, _} -> {:error, :stat_failed}
    end
  end

  defp parse_by_type(path, "image/" <> _ = mime) do
    Media.Parsers.Image.parse(path, mime)
  end

  defp parse_by_type(path, "audio/" <> _ = mime) do
    Media.Parsers.Audio.parse(path, mime)
  end

  defp parse_by_type(path, "video/" <> _ = mime) do
    Media.Parsers.Video.parse(path, mime)
  end

  defp parse_by_type(_path, _mime) do
    {:ok, %{}}
  end

  defp normalise(raw_meta, mime_type, file_size) do
    %{
      mime_type: mime_type,
      file_size_bytes: file_size,
      width_px: Map.get(raw_meta, :width_px),
      height_px: Map.get(raw_meta, :height_px),
      duration_seconds: Map.get(raw_meta, :duration_seconds),
      title: Map.get(raw_meta, :title),
      author: Map.get(raw_meta, :author),
      created_at: Map.get(raw_meta, :created_at),
      extra: Map.drop(raw_meta, [:width_px, :height_px, :duration_seconds, :title, :author, :created_at])
    }
  end
end
```
