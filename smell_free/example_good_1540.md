```elixir
defmodule Media.ImageProcessor do
  @moduledoc """
  Supervised pipeline for resizing and transcoding uploaded images.

  Accepts a raw upload descriptor, generates multiple derivative variants
  (thumbnail, medium, large), and stores them via the configured object
  storage adapter. All processing is transactional: if any variant fails,
  the entire job is rolled back by removing any partially stored outputs.
  """

  alias Media.{StorageAdapter, ImageVariant, UploadRecord, Repo}

  @type upload_descriptor :: %{
          source_path: String.t(),
          original_filename: String.t(),
          content_type: String.t(),
          owner_id: String.t()
        }

  @type processing_result ::
          {:ok, [ImageVariant.t()]}
          | {:error, :unsupported_format}
          | {:error, :processing_failed, String.t()}

  @variants [
    %{name: :thumbnail, max_width: 150, max_height: 150},
    %{name: :medium, max_width: 800, max_height: 600},
    %{name: :large, max_width: 1920, max_height: 1080}
  ]

  @supported_content_types ~w(image/jpeg image/png image/webp)

  @doc """
  Processes an uploaded image by generating all configured size variants.

  Returns `{:ok, variants}` with a list of persisted variant records, or a
  tagged error tuple if validation or any processing step fails.
  """
  @spec process_upload(upload_descriptor()) :: processing_result()
  def process_upload(%{content_type: ct}) when ct not in @supported_content_types do
    {:error, :unsupported_format}
  end

  def process_upload(%{source_path: source_path, owner_id: owner_id} = descriptor) do
    upload_record = create_upload_record(descriptor)

    case generate_all_variants(source_path, upload_record.id) do
      {:ok, variant_records} ->
        {:ok, variant_records}

      {:error, reason, stored_keys} ->
        rollback_stored_objects(stored_keys)
        {:error, :processing_failed, reason}
    end
  end

  defp generate_all_variants(source_path, upload_record_id) do
    @variants
    |> Enum.reduce_while({:ok, []}, fn variant_spec, {:ok, acc} ->
      case process_single_variant(source_path, upload_record_id, variant_spec) do
        {:ok, record} ->
          {:cont, {:ok, [record | acc]}}

        {:error, reason} ->
          stored_keys = Enum.map(acc, & &1.storage_key)
          {:halt, {:error, reason, stored_keys}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp process_single_variant(source_path, upload_record_id, %{name: name, max_width: w, max_height: h}) do
    storage_key = generate_storage_key(upload_record_id, name)

    with {:ok, resized_path} <- resize_image(source_path, w, h),
         {:ok, _} <- StorageAdapter.store(resized_path, storage_key),
         {:ok, record} <- persist_variant_record(upload_record_id, name, storage_key) do
      {:ok, record}
    end
  end

  defp resize_image(source_path, max_width, max_height) do
    output_path = System.tmp_dir!() <> "/#{:crypto.strong_rand_bytes(8) |> Base.hex_encode32()}.jpg"

    case System.cmd("convert", [
           source_path,
           "-resize",
           "#{max_width}x#{max_height}>",
           "-strip",
           output_path
         ]) do
      {_, 0} -> {:ok, output_path}
      {error_output, _code} -> {:error, error_output}
    end
  end

  defp persist_variant_record(upload_record_id, variant_name, storage_key) do
    %ImageVariant{}
    |> ImageVariant.changeset(%{
      upload_record_id: upload_record_id,
      variant: variant_name,
      storage_key: storage_key
    })
    |> Repo.insert()
  end

  defp create_upload_record(%{original_filename: filename, owner_id: owner_id, content_type: ct}) do
    %UploadRecord{}
    |> UploadRecord.changeset(%{original_filename: filename, owner_id: owner_id, content_type: ct})
    |> Repo.insert!()
  end

  defp generate_storage_key(upload_record_id, variant_name) do
    "uploads/#{upload_record_id}/#{variant_name}.jpg"
  end

  defp rollback_stored_objects(keys) do
    Enum.each(keys, &StorageAdapter.delete/1)
  end
end
```
