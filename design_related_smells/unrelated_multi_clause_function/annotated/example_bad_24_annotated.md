# Annotated Example 24

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `AssetPipeline.transform/1`
- **Affected function(s):** `transform/1`
- **Short explanation:** `transform/1` handles image resizing, video transcoding, and PDF thumbnail generation — three unrelated media processing operations — collapsed into one multi-clause function. Each clause uses different external tools, processing parameters, and storage strategies.

```elixir
defmodule AssetPipeline do
  @moduledoc """
  Media asset transformation pipeline for the content platform.
  Handles image resizing, video transcoding, and PDF thumbnail generation.
  """

  alias AssetPipeline.{
    ImageTransformJob,
    VideoTranscodeJob,
    PdfThumbnailJob,
    ImageProcessor,
    VideoEncoder,
    PdfRenderer,
    StorageBucket,
    CDNInvalidator,
    JobStore,
    MetadataStore
  }

  require Logger

  @doc """
  Transform a media asset according to the job specification.

  Accepts an `%ImageTransformJob{}`, `%VideoTranscodeJob{}`, or `%PdfThumbnailJob{}`
  and performs the corresponding media transformation.

  ## Examples

      iex> AssetPipeline.transform(%ImageTransformJob{asset_id: "img_001", width: 800, format: :webp})
      {:ok, %{output_url: "https://cdn.example.com/img_001_800.webp"}}

  """
  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because resizing images, transcoding video,
  # and rendering PDF thumbnails are completely different media operations
  # involving separate external tools (ImageMagick vs FFmpeg vs Ghostscript),
  # distinct quality parameters, and different CDN strategies. Fusing them
  # under `transform/1` is an abuse of multi-clause pattern matching.

  def transform(%ImageTransformJob{
        asset_id: asset_id,
        source_url: source_url,
        width: width,
        height: height,
        format: format,
        quality: quality
      }) do
    with {:ok, source_path} <- StorageBucket.download_temp(source_url),
         {:ok, output_path} <-
           ImageProcessor.resize(%{
             input: source_path,
             width: width,
             height: height,
             format: format,
             quality: quality,
             strip_metadata: true
           }),
         output_key = "images/#{asset_id}_#{width}x#{height}.#{format}",
         {:ok, output_url} <- StorageBucket.upload(output_key, output_path),
         :ok <- MetadataStore.record_variant(asset_id, %{width: width, height: height, format: format, url: output_url}),
         :ok <- CDNInvalidator.purge(output_key),
         :ok <- cleanup_temp([source_path, output_path]) do
      Logger.info("Image #{asset_id} resized to #{width}x#{height} as #{format}")
      {:ok, %{output_url: output_url, width: width, height: height}}
    end
  end

  # transform video asset by transcoding to target codec and resolution
  def transform(%VideoTranscodeJob{
        asset_id: asset_id,
        source_url: source_url,
        codec: codec,
        resolution: resolution,
        bitrate: bitrate,
        generate_thumbnail: gen_thumb
      })
      when codec in [:h264, :h265, :vp9] do
    with {:ok, source_path} <- StorageBucket.download_temp(source_url),
         {:ok, output_path} <-
           VideoEncoder.transcode(%{
             input: source_path,
             codec: codec,
             resolution: resolution,
             bitrate: bitrate,
             two_pass: codec == :h265
           }),
         output_key = "videos/#{asset_id}_#{resolution}_#{codec}.mp4",
         {:ok, output_url} <- StorageBucket.upload(output_key, output_path),
         {:ok, thumb_url} <- maybe_generate_video_thumbnail(gen_thumb, source_path, asset_id),
         :ok <-
           MetadataStore.record_variant(asset_id, %{
             codec: codec,
             resolution: resolution,
             url: output_url,
             thumbnail_url: thumb_url
           }),
         :ok <- cleanup_temp([source_path, output_path]) do
      Logger.info("Video #{asset_id} transcoded to #{codec}/#{resolution}")
      {:ok, %{output_url: output_url, thumbnail_url: thumb_url}}
    end
  end

  # transform PDF document by generating preview thumbnail image
  def transform(%PdfThumbnailJob{
        asset_id: asset_id,
        source_url: source_url,
        page: page,
        width: width,
        format: format
      })
      when page >= 1 do
    with {:ok, source_path} <- StorageBucket.download_temp(source_url),
         {:ok, thumb_path} <-
           PdfRenderer.render_page(%{
             input: source_path,
             page: page,
             width: width,
             format: format,
             dpi: 150
           }),
         output_key = "pdf_thumbs/#{asset_id}_p#{page}_#{width}.#{format}",
         {:ok, output_url} <- StorageBucket.upload(output_key, thumb_path),
         :ok <- MetadataStore.record_pdf_thumbnail(asset_id, page, output_url),
         :ok <- cleanup_temp([source_path, thumb_path]) do
      Logger.info("PDF thumbnail generated for #{asset_id} page #{page}")
      {:ok, %{output_url: output_url, page: page}}
    end
  end

  # VALIDATION: SMELL END

  defp maybe_generate_video_thumbnail(true, source_path, asset_id) do
    with {:ok, thumb_path} <- VideoEncoder.extract_frame(source_path, at_second: 5),
         key = "video_thumbs/#{asset_id}_thumb.jpg",
         {:ok, url} <- StorageBucket.upload(key, thumb_path),
         :ok <- cleanup_temp([thumb_path]) do
      {:ok, url}
    end
  end

  defp maybe_generate_video_thumbnail(false, _source_path, _asset_id), do: {:ok, nil}

  defp cleanup_temp(paths) do
    Enum.each(paths, fn path ->
      File.rm(path)
    end)

    :ok
  end
end
```
