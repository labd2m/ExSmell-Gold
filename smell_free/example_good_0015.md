# File: `example_good_15.md`

```elixir
defmodule Media.ImageProcessor do
  @moduledoc """
  Processes uploaded images through a configurable sequence of
  transformation steps and writes each output variant to storage.

  Steps are pure functions grouped into a pipeline. The processor
  does not own storage or HTTP concerns — those are injected via
  the `storage` option so implementations remain testable.
  """

  alias Media.{ImageVariant, StorageAdapter}

  @type image_bytes :: binary()
  @type variant_name :: atom()

  @type variant_spec :: %{
          required(:name) => variant_name(),
          required(:width) => pos_integer(),
          required(:height) => pos_integer(),
          required(:format) => :jpeg | :webp | :png,
          optional(:quality) => 1..100
        }

  @type process_opts :: [
          storage: module(),
          prefix: String.t()
        ]

  @type process_result ::
          {:ok, [ImageVariant.t()]}
          | {:error, :invalid_image}
          | {:error, :storage_failed, variant_name()}

  @default_quality 85

  @doc """
  Processes `image_bytes` through each variant spec in `specs`,
  uploading each output to the configured storage backend.

  Options:
  - `:storage` — a module implementing `StorageAdapter` behaviour (required)
  - `:prefix` — storage key prefix for uploaded files

  Returns `{:ok, variants}` on full success. If any variant fails to
  upload, returns `{:error, :storage_failed, variant_name}` immediately.
  """
  @spec process(image_bytes(), [variant_spec()], process_opts()) :: process_result()
  def process(image_bytes, specs, opts)
      when is_binary(image_bytes) and is_list(specs) and is_list(opts) do
    storage = Keyword.fetch!(opts, :storage)
    prefix = Keyword.get(opts, :prefix, "")

    with {:ok, source_image} <- decode_image(image_bytes) do
      generate_and_upload_variants(source_image, specs, storage, prefix)
    end
  end

  defp decode_image(bytes) do
    case :image.from_binary(bytes) do
      {:ok, _img} = ok -> ok
      {:error, _reason} -> {:error, :invalid_image}
    end
  end

  defp generate_and_upload_variants(source, specs, storage, prefix) do
    Enum.reduce_while(specs, {:ok, []}, fn spec, {:ok, acc} ->
      spec
      |> generate_variant(source)
      |> upload_variant(spec, storage, prefix)
      |> handle_upload_result(spec, acc)
    end)
  end

  defp generate_variant(spec, source) do
    quality = Map.get(spec, :quality, @default_quality)

    source
    |> resize(spec.width, spec.height)
    |> encode(spec.format, quality)
  end

  defp resize(image, width, height) do
    :image.resize(image, width, height, fit: :cover)
  end

  defp encode(image, :jpeg, quality), do: :image.to_jpeg(image, quality: quality)
  defp encode(image, :webp, quality), do: :image.to_webp(image, quality: quality)
  defp encode(image, :png, _quality), do: :image.to_png(image)

  defp upload_variant({:ok, encoded_bytes}, spec, storage, prefix) do
    key = build_storage_key(prefix, spec.name, spec.format)

    case storage.put(key, encoded_bytes, content_type(spec.format)) do
      {:ok, url} ->
        variant = %ImageVariant{
          name: spec.name,
          url: url,
          width: spec.width,
          height: spec.height,
          format: spec.format,
          size_bytes: byte_size(encoded_bytes)
        }

        {:ok, variant}

      {:error, _reason} ->
        {:error, :storage_failed}
    end
  end

  defp upload_variant({:error, _reason}, _spec, _storage, _prefix) do
    {:error, :encode_failed}
  end

  defp handle_upload_result({:ok, variant}, _spec, acc) do
    {:cont, {:ok, [variant | acc]}}
  end

  defp handle_upload_result({:error, :storage_failed}, spec, _acc) do
    {:halt, {:error, :storage_failed, spec.name}}
  end

  defp handle_upload_result({:error, _reason}, spec, _acc) do
    {:halt, {:error, :storage_failed, spec.name}}
  end

  defp build_storage_key(prefix, name, format) do
    ext = Atom.to_string(format)
    base = Atom.to_string(name)

    if prefix == "" do
      "#{base}.#{ext}"
    else
      "#{prefix}/#{base}.#{ext}"
    end
  end

  defp content_type(:jpeg), do: "image/jpeg"
  defp content_type(:webp), do: "image/webp"
  defp content_type(:png), do: "image/png"
end
```
