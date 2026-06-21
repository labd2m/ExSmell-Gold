```elixir
defmodule MyApp.Media.ImageProcessor do
  @moduledoc """
  Validates, resizes, and stores uploaded images using supervised Task
  processes for concurrent variant generation. Each variant is produced
  by a discrete private function so that the resize pipeline can be
  extended without changing the orchestration logic.

  All file operations are performed in a unique temporary directory that
  is cleaned up regardless of success or failure.
  """

  require Logger

  @variants [
    %{name: :thumbnail, width: 150, height: 150, crop: true},
    %{name: :medium, width: 640, height: nil, crop: false},
    %{name: :large, width: 1280, height: nil, crop: false}
  ]

  @allowed_mime_types ~w(image/jpeg image/png image/webp)
  @max_bytes 10 * 1024 * 1024

  @type upload :: %{path: String.t(), content_type: String.t(), size: non_neg_integer()}
  @type variant_name :: :thumbnail | :medium | :large
  @type stored_variant :: %{name: variant_name(), url: String.t(), size_bytes: non_neg_integer()}

  @doc """
  Validates and processes an uploaded image, producing all configured
  size variants concurrently. Returns a map of variant names to stored
  variant metadata, or a structured error tuple on failure.
  """
  @spec process(upload(), String.t()) ::
          {:ok, %{variant_name() => stored_variant()}} | {:error, term()}
  def process(upload, object_key_prefix) when is_binary(object_key_prefix) do
    with :ok <- validate_upload(upload) do
      work_dir = make_work_dir()

      try do
        produce_variants(upload.path, work_dir, object_key_prefix)
      after
        File.rm_rf!(work_dir)
      end
    end
  end

  @spec validate_upload(upload()) :: :ok | {:error, term()}
  defp validate_upload(upload) do
    cond do
      upload.content_type not in @allowed_mime_types ->
        {:error, {:unsupported_type, upload.content_type}}

      upload.size > @max_bytes ->
        {:error, {:file_too_large, upload.size}}

      not File.exists?(upload.path) ->
        {:error, :source_not_found}

      true ->
        :ok
    end
  end

  @spec produce_variants(String.t(), String.t(), String.t()) ::
          {:ok, %{variant_name() => stored_variant()}} | {:error, term()}
  defp produce_variants(source_path, work_dir, key_prefix) do
    tasks =
      Enum.map(@variants, fn variant ->
        Task.async(fn -> process_variant(source_path, work_dir, key_prefix, variant) end)
      end)

    results = Task.await_many(tasks, 30_000)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        stored = Map.new(results, fn {:ok, sv} -> {sv.name, sv} end)
        {:ok, stored}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec process_variant(String.t(), String.t(), String.t(), map()) ::
          {:ok, stored_variant()} | {:error, term()}
  defp process_variant(source_path, work_dir, key_prefix, variant) do
    out_path = Path.join(work_dir, "#{variant.name}.webp")

    with :ok <- resize_image(source_path, out_path, variant),
         {:ok, url} <- upload_to_storage(out_path, "#{key_prefix}/#{variant.name}.webp"),
         {:ok, %{size: size}} <- File.stat(out_path) do
      {:ok, %{name: variant.name, url: url, size_bytes: size}}
    end
  end

  @spec resize_image(String.t(), String.t(), map()) :: :ok | {:error, term()}
  defp resize_image(src, dest, %{width: w, height: h, crop: crop}) do
    MyApp.ImageMagick.convert(src, dest, width: w, height: h, crop: crop, format: :webp)
  end

  @spec upload_to_storage(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp upload_to_storage(local_path, object_key) do
    MyApp.Storage.upload(local_path, object_key, acl: :public_read)
  end

  @spec make_work_dir() :: String.t()
  defp make_work_dir do
    dir = Path.join(System.tmp_dir!(), "img_proc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end
end
```
