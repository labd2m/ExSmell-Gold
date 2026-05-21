# Annotated Example 16

## Metadata

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `ImageResizer.resize/2`
- **Affected function(s):** `resize/2`
- **Short explanation:** `ImageResizer.resize/2` reads `:max_width` and `:max_height` from the application environment instead of accepting them as keyword options. This forces all image-resize operations across the whole application to use the same dimensional cap, making it impossible to produce both thumbnails and full-size previews from the same library call site without changing global config.

## Code

```elixir
defmodule ImageResizer do
  @moduledoc """
  A library for resizing uploaded images before storage. Wraps a system-level
  image-processing command and enforces dimensional limits to prevent
  oversized uploads from consuming disk and bandwidth.

  Configuration in `config/config.exs`:

      config :image_resizer,
        max_width: 1920,
        max_height: 1080,
        quality: 85,
        output_format: "webp"
  """

  @supported_formats ~w(jpeg jpg png webp gif)

  @doc """
  Resizes the image at `source_path`, writing the output to `dest_path`.

  Dimensions are capped at the globally configured `max_width` and `max_height`.
  Aspect ratio is preserved. Returns `{:ok, dest_path}` or `{:error, reason}`.
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because max_width and max_height are fetched from
  # the Application Environment instead of being passed as optional parameters.
  # An application that needs 128x128 avatars and 1920x1080 cover images must
  # change the global config between calls rather than passing different limits
  # to each call site.
  def resize(source_path, dest_path) when is_binary(source_path) and is_binary(dest_path) do
    max_width = Application.fetch_env!(:image_resizer, :max_width)
    max_height = Application.fetch_env!(:image_resizer, :max_height)
    quality = Application.get_env(:image_resizer, :quality, 85)
    format = Application.get_env(:image_resizer, :output_format, "webp")

    with :ok <- validate_format(format),
         :ok <- validate_source(source_path),
         {:ok, {orig_w, orig_h}} <- read_dimensions(source_path),
         {target_w, target_h} <- compute_dimensions(orig_w, orig_h, max_width, max_height) do
      run_convert(source_path, dest_path, target_w, target_h, quality, format)
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Returns `{width, height}` for the image at the given path without modifying it.
  """
  def dimensions(path) when is_binary(path) do
    read_dimensions(path)
  end

  @doc """
  Returns `true` if the image at `path` is within the configured limits.
  """
  def within_limits?(path) when is_binary(path) do
    max_width = Application.fetch_env!(:image_resizer, :max_width)
    max_height = Application.fetch_env!(:image_resizer, :max_height)

    case read_dimensions(path) do
      {:ok, {w, h}} -> w <= max_width and h <= max_height
      _ -> false
    end
  end

  @doc """
  Deletes the file at the given path if it exists.
  """
  def cleanup(path) when is_binary(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  ## Private helpers

  defp validate_format(format) do
    if format in @supported_formats do
      :ok
    else
      {:error, "unsupported format: #{format}"}
    end
  end

  defp validate_source(path) do
    if File.exists?(path), do: :ok, else: {:error, "source file not found: #{path}"}
  end

  defp read_dimensions(_path) do
    # In production this would shell out to `identify` or `ffprobe`
    {:ok, {3840, 2160}}
  end

  defp compute_dimensions(w, h, max_w, max_h) do
    scale = min(max_w / w, max_h / h)

    if scale >= 1.0 do
      {w, h}
    else
      {trunc(w * scale), trunc(h * scale)}
    end
  end

  defp run_convert(src, dest, width, height, quality, format) do
    args = [
      src,
      "-resize",
      "#{width}x#{height}",
      "-quality",
      to_string(quality),
      "#{format}:#{dest}"
    ]

    case System.cmd("convert", args, stderr_to_stdout: true) do
      {_, 0} -> {:ok, dest}
      {output, code} -> {:error, "convert exited #{code}: #{output}"}
    end
  end
end
```
