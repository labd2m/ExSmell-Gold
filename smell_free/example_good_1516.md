```elixir
defmodule Media.ImageProcessor do
  @moduledoc """
  Orchestrates multi-step image transformation pipelines for uploaded
  media assets.

  Each transformation step (resize, watermark, format conversion) is
  handled by a dedicated private function, keeping each concern isolated
  and independently testable.
  """

  alias Media.Asset
  alias Media.ImageAdapter
  alias Media.StorageClient

  @type transform_opts :: [
          resize: {pos_integer(), pos_integer()},
          format: :jpeg | :webp | :png,
          watermark: String.t() | nil,
          quality: 1..100
        ]

  @type processing_result ::
          {:ok, Asset.t()} | {:error, :download_failed | :transform_failed | :upload_failed}

  @doc """
  Downloads a source asset, applies the given transformations, and
  uploads the resulting file to storage.

  Returns the updated `Asset` struct with the new storage URL on success.
  """
  @spec process(Asset.t(), transform_opts()) :: processing_result()
  def process(%Asset{source_url: source_url} = asset, opts) when is_list(opts) do
    with {:ok, raw_bytes} <- download(source_url),
         {:ok, transformed} <- transform(raw_bytes, opts),
         {:ok, upload_url} <- upload(asset, transformed, opts) do
      {:ok, %Asset{asset | processed_url: upload_url, status: :ready}}
    end
  end

  @spec download(String.t()) :: {:ok, binary()} | {:error, :download_failed}
  defp download(url) when is_binary(url) do
    case ImageAdapter.fetch(url) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      _ -> {:error, :download_failed}
    end
  end

  @spec transform(binary(), transform_opts()) :: {:ok, binary()} | {:error, :transform_failed}
  defp transform(bytes, opts) do
    result =
      bytes
      |> maybe_resize(Keyword.get(opts, :resize))
      |> maybe_convert_format(Keyword.get(opts, :format, :jpeg))
      |> maybe_apply_watermark(Keyword.get(opts, :watermark))
      |> maybe_set_quality(Keyword.get(opts, :quality, 85))

    case result do
      {:ok, _} = success -> success
      _ -> {:error, :transform_failed}
    end
  end

  @spec maybe_resize({:ok, binary()} | {:error, term()}, {pos_integer(), pos_integer()} | nil) ::
          {:ok, binary()} | {:error, term()}
  defp maybe_resize({:error, _} = err, _opts), do: err
  defp maybe_resize({:ok, bytes}, nil), do: {:ok, bytes}

  defp maybe_resize({:ok, bytes}, {width, height})
       when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    ImageAdapter.resize(bytes, width, height)
  end

  @spec maybe_convert_format({:ok, binary()} | {:error, term()}, atom()) ::
          {:ok, binary()} | {:error, term()}
  defp maybe_convert_format({:error, _} = err, _fmt), do: err

  defp maybe_convert_format({:ok, bytes}, format) when format in [:jpeg, :webp, :png] do
    ImageAdapter.convert(bytes, format)
  end

  @spec maybe_apply_watermark({:ok, binary()} | {:error, term()}, String.t() | nil) ::
          {:ok, binary()} | {:error, term()}
  defp maybe_apply_watermark({:error, _} = err, _), do: err
  defp maybe_apply_watermark({:ok, bytes}, nil), do: {:ok, bytes}

  defp maybe_apply_watermark({:ok, bytes}, text) when is_binary(text) do
    ImageAdapter.watermark(bytes, text)
  end

  @spec maybe_set_quality({:ok, binary()} | {:error, term()}, 1..100) ::
          {:ok, binary()} | {:error, term()}
  defp maybe_set_quality({:error, _} = err, _quality), do: err

  defp maybe_set_quality({:ok, bytes}, quality)
       when is_integer(quality) and quality >= 1 and quality <= 100 do
    ImageAdapter.set_quality(bytes, quality)
  end

  @spec upload(Asset.t(), binary(), transform_opts()) ::
          {:ok, String.t()} | {:error, :upload_failed}
  defp upload(%Asset{id: asset_id}, bytes, opts) do
    format = Keyword.get(opts, :format, :jpeg)
    path = "processed/#{asset_id}.#{format}"

    case StorageClient.put(path, bytes, content_type(format)) do
      {:ok, url} -> {:ok, url}
      {:error, _} -> {:error, :upload_failed}
    end
  end

  @spec content_type(atom()) :: String.t()
  defp content_type(:jpeg), do: "image/jpeg"
  defp content_type(:webp), do: "image/webp"
  defp content_type(:png), do: "image/png"
end
```
