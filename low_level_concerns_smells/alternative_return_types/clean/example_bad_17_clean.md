```elixir
defmodule MyApp.Media.Uploader do
  @moduledoc """
  Handles media file uploads to cloud storage. Performs validation,
  virus scanning, image resizing, and CDN cache priming. Used by the
  user profile, product catalog, and document management modules.
  """

  alias MyApp.Media.StorageBackend
  alias MyApp.Media.VirusScanner
  alias MyApp.Media.ImageProcessor
  alias MyApp.Media.CdnPrimer
  alias MyApp.Repo

  defstruct [
    :id, :original_filename, :content_type,
    :size_bytes, :storage_key, :public_url,
    :owner_id, :uploaded_at, :variants
  ]

  @allowed_types ~w(image/jpeg image/png image/webp application/pdf)
  @max_size_bytes 20_971_520
  @image_types ~w(image/jpeg image/png image/webp)

  def build_upload(file_path, owner_id, opts \\ []) do
    %{
      file_path: file_path,
      owner_id: owner_id,
      content_type: opts[:content_type] || detect_content_type(file_path),
      original_filename: opts[:filename] || Path.basename(file_path)
    }
  end

  def upload(upload_params, opts \\ []) when is_list(opts) do
    result = Keyword.get(opts, :result, :url)
    scan = Keyword.get(opts, :scan, true)
    resize = Keyword.get(opts, :resize, false)
    prime_cdn = Keyword.get(opts, :prime_cdn, false)

    content_type = upload_params.content_type

    with :ok <- validate_content_type(content_type),
         :ok <- validate_file_size(upload_params.file_path),
         :ok <- maybe_scan(upload_params.file_path, scan) do
      processed_path =
        if resize and content_type in @image_types do
          ImageProcessor.resize(upload_params.file_path)
        else
          upload_params.file_path
        end

      storage_key = generate_storage_key(upload_params.original_filename)

      with {:ok, public_url} <- StorageBackend.put(storage_key, processed_path, content_type) do
        if prime_cdn, do: CdnPrimer.prime(public_url)

        asset = %__MODULE__{
          id: generate_id(),
          original_filename: upload_params.original_filename,
          content_type: content_type,
          size_bytes: File.stat!(processed_path).size,
          storage_key: storage_key,
          public_url: public_url,
          owner_id: upload_params.owner_id,
          uploaded_at: DateTime.utc_now(),
          variants: []
        }

        Repo.insert!(asset)

        case result do
          :url ->
            public_url

          :asset ->
            asset

          :full ->
            {:ok, public_url, asset}
        end
      end
    end
  end

  def delete(asset_id) do
    with {:ok, asset} <- Repo.fetch(__MODULE__, asset_id),
         :ok <- StorageBackend.delete(asset.storage_key) do
      Repo.delete(asset)
    end
  end

  def variants_for(asset_id) do
    with {:ok, asset} <- Repo.fetch(__MODULE__, asset_id) do
      {:ok, asset.variants}
    end
  end

  defp validate_content_type(ct) when ct in @allowed_types, do: :ok
  defp validate_content_type(ct), do: {:error, {:unsupported_type, ct}}

  defp validate_file_size(path) do
    stat = File.stat!(path)
    if stat.size <= @max_size_bytes, do: :ok, else: {:error, :file_too_large}
  end

  defp maybe_scan(_path, false), do: :ok
  defp maybe_scan(path, true), do: VirusScanner.scan(path)

  defp generate_storage_key(filename) do
    ts = System.system_time(:millisecond)
    ext = Path.extname(filename)
    "uploads/#{ts}_#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}#{ext}"
  end

  defp generate_id, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  defp detect_content_type(_path), do: "application/octet-stream"
end
```
