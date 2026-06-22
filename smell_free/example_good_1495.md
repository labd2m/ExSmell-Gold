```elixir
defmodule FileProcessor.ImageIngestion do
  @moduledoc """
  Ingests uploaded image files, validates their format and size,
  generates metadata records, and hands off to storage.
  """

  alias FileProcessor.{ImageMetadata, StorageClient}

  @max_file_size_bytes 10 * 1024 * 1024
  @supported_formats ["image/jpeg", "image/png", "image/webp"]

  @type ingest_opts :: [owner_id: String.t(), tags: [String.t()]]
  @type ingest_result :: {:ok, ImageMetadata.t()} | {:error, String.t()}

  @spec ingest(String.t(), binary(), String.t(), ingest_opts()) :: ingest_result()
  def ingest(filename, content, content_type, opts)
      when is_binary(filename) and is_binary(content) and is_binary(content_type) do
    with :ok <- validate_format(content_type),
         :ok <- validate_size(content),
         {:ok, dimensions} <- extract_dimensions(content, content_type),
         {:ok, storage_key} <- StorageClient.store(filename, content, content_type) do
      metadata = ImageMetadata.new(%{
        filename: filename,
        storage_key: storage_key,
        content_type: content_type,
        size_bytes: byte_size(content),
        width: dimensions.width,
        height: dimensions.height,
        owner_id: Keyword.get(opts, :owner_id),
        tags: Keyword.get(opts, :tags, [])
      })

      {:ok, metadata}
    end
  end

  @spec validate_format(String.t()) :: :ok | {:error, String.t()}
  defp validate_format(content_type) do
    if content_type in @supported_formats do
      :ok
    else
      {:error, "Unsupported format: #{content_type}. Supported: #{Enum.join(@supported_formats, ", ")}"}
    end
  end

  @spec validate_size(binary()) :: :ok | {:error, String.t()}
  defp validate_size(content) do
    size = byte_size(content)

    if size <= @max_file_size_bytes do
      :ok
    else
      max_mb = div(@max_file_size_bytes, 1024 * 1024)
      {:error, "File too large: #{div(size, 1024)}KB exceeds #{max_mb}MB limit"}
    end
  end

  @spec extract_dimensions(binary(), String.t()) ::
          {:ok, %{width: pos_integer(), height: pos_integer()}} | {:error, String.t()}
  defp extract_dimensions(content, "image/png") do
    parse_png_dimensions(content)
  end

  defp extract_dimensions(content, "image/jpeg") do
    parse_jpeg_dimensions(content)
  end

  defp extract_dimensions(_content, "image/webp") do
    {:ok, %{width: 0, height: 0}}
  end

  defp extract_dimensions(_, type), do: {:error, "Cannot extract dimensions for #{type}"}

  @spec parse_png_dimensions(binary()) ::
          {:ok, %{width: pos_integer(), height: pos_integer()}} | {:error, String.t()}
  defp parse_png_dimensions(<<137, 80, 78, 71, 13, 10, 26, 10, _::binary-size(8),
                               width::big-unsigned-integer-size(32),
                               height::big-unsigned-integer-size(32), _::binary>>) do
    {:ok, %{width: width, height: height}}
  end

  defp parse_png_dimensions(_), do: {:error, "Invalid PNG header"}

  @spec parse_jpeg_dimensions(binary()) ::
          {:ok, %{width: pos_integer(), height: pos_integer()}} | {:error, String.t()}
  defp parse_jpeg_dimensions(<<0xFF, 0xD8, rest::binary>>) do
    scan_jpeg_segments(rest)
  end

  defp parse_jpeg_dimensions(_), do: {:error, "Invalid JPEG header"}

  @spec scan_jpeg_segments(binary()) ::
          {:ok, %{width: pos_integer(), height: pos_integer()}} | {:error, String.t()}
  defp scan_jpeg_segments(<<0xFF, 0xC0, _len::16, _precision::8,
                             height::big-unsigned-integer-size(16),
                             width::big-unsigned-integer-size(16), _::binary>>) do
    {:ok, %{width: width, height: height}}
  end

  defp scan_jpeg_segments(<<0xFF, _marker::8, length::big-unsigned-integer-size(16), rest::binary>>) do
    skip = length - 2
    case rest do
      <<_::binary-size(skip), remaining::binary>> -> scan_jpeg_segments(remaining)
      _ -> {:error, "Malformed JPEG segment"}
    end
  end

  defp scan_jpeg_segments(_), do: {:error, "Could not find JPEG SOF marker"}
end
```
