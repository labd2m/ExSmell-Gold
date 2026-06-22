```elixir
defmodule Media.ImageTransformer do
  @moduledoc """
  Applies a declarative transformation pipeline to uploaded images.
  Each transformation step is independently validated and executed in sequence.
  """

  @type dimensions :: %{width: pos_integer(), height: pos_integer()}

  @type transform ::
          {:resize, dimensions()}
          | {:crop, %{x: non_neg_integer(), y: non_neg_integer()} | dimensions()}
          | {:convert, :jpeg | :png | :webp}
          | {:quality, 1..100}

  @type transform_result :: {:ok, binary()} | {:error, atom()}

  @spec transform(binary(), [transform()]) :: transform_result()
  def transform(image_binary, transforms)
      when is_binary(image_binary) and is_list(transforms) do
    Enum.reduce_while(transforms, {:ok, image_binary}, fn transform, {:ok, current} ->
      case apply_transform(current, transform) do
        {:ok, result} -> {:cont, {:ok, result}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec apply_transform(binary(), transform()) :: transform_result()
  defp apply_transform(image, {:resize, %{width: w, height: h}})
       when is_integer(w) and w > 0 and is_integer(h) and h > 0 do
    Mogrify.open_from_binary(image)
    |> Mogrify.resize("#{w}x#{h}")
    |> Mogrify.save(in_place: true)
    |> read_back()
  end

  defp apply_transform(image, {:crop, %{x: x, y: y, width: w, height: h}}) do
    Mogrify.open_from_binary(image)
    |> Mogrify.custom("crop", "#{w}x#{h}+#{x}+#{y}")
    |> Mogrify.save(in_place: true)
    |> read_back()
  end

  defp apply_transform(image, {:convert, format}) when format in [:jpeg, :png, :webp] do
    ext = to_string(format)

    Mogrify.open_from_binary(image)
    |> Mogrify.format(ext)
    |> Mogrify.save(in_place: true)
    |> read_back()
  end

  defp apply_transform(image, {:quality, level}) when level in 1..100 do
    Mogrify.open_from_binary(image)
    |> Mogrify.custom("quality", to_string(level))
    |> Mogrify.save(in_place: true)
    |> read_back()
  end

  defp apply_transform(_image, invalid_transform) do
    {:error, {:unsupported_transform, invalid_transform}}
  end

  @spec read_back(Mogrify.Image.t()) :: transform_result()
  defp read_back(%Mogrify.Image{path: path}) do
    case File.read(path) do
      {:ok, binary} ->
        File.rm(path)
        {:ok, binary}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```
