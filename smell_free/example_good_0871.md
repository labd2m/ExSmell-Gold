```elixir
defmodule MyApp.Media.ImageVariantStore do
  @moduledoc """
  Manages the lifecycle of image variants: stores upload metadata,
  tracks which variants have been generated, and provides a clean API
  for querying URLs without coupling callers to storage key conventions.
  All URL construction is centralised here so that migrating storage
  providers requires changes in only one place.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Media.{ImageAsset, ImageVariant}

  @cdn_base_url Application.compile_env(:my_app, :cdn_base_url, "https://cdn.example.com")

  @valid_variants [:original, :thumbnail, :medium, :large, :webp_thumb]

  @type asset_id :: String.t()
  @type variant :: :original | :thumbnail | :medium | :large | :webp_thumb

  @doc """
  Creates an `ImageAsset` record for a newly uploaded file before
  variants are generated.
  """
  @spec register_upload(map()) :: {:ok, ImageAsset.t()} | {:error, Ecto.Changeset.t()}
  def register_upload(attrs) when is_map(attrs) do
    %ImageAsset{}
    |> ImageAsset.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Records that `variant` has been generated and stored at `storage_key`
  for `asset_id`.
  """
  @spec record_variant(asset_id(), variant(), String.t(), non_neg_integer()) ::
          {:ok, ImageVariant.t()} | {:error, Ecto.Changeset.t()}
  def record_variant(asset_id, variant, storage_key, size_bytes)
      when is_binary(asset_id) and variant in @valid_variants do
    %ImageVariant{}
    |> ImageVariant.changeset(%{
      asset_id: asset_id,
      variant: variant,
      storage_key: storage_key,
      size_bytes: size_bytes,
      generated_at: DateTime.utc_now()
    })
    |> Repo.insert(
      on_conflict: {:replace, [:storage_key, :size_bytes, :generated_at, :updated_at]},
      conflict_target: [:asset_id, :variant]
    )
  end

  @doc "Returns the CDN URL for `variant` of `asset_id`, or `nil` if not generated."
  @spec url(asset_id(), variant()) :: String.t() | nil
  def url(asset_id, variant) when is_binary(asset_id) and variant in @valid_variants do
    case Repo.get_by(ImageVariant, asset_id: asset_id, variant: variant) do
      nil -> nil
      image_variant -> cdn_url(image_variant.storage_key)
    end
  end

  @doc "Returns a map of variant atom to URL for all generated variants of `asset_id`."
  @spec all_urls(asset_id()) :: %{variant() => String.t()}
  def all_urls(asset_id) when is_binary(asset_id) do
    ImageVariant
    |> where([v], v.asset_id == ^asset_id)
    |> Repo.all()
    |> Map.new(fn v -> {v.variant, cdn_url(v.storage_key)} end)
  end

  @doc "Returns which variants are still missing for `asset_id`."
  @spec missing_variants(asset_id()) :: [variant()]
  def missing_variants(asset_id) when is_binary(asset_id) do
    generated =
      ImageVariant
      |> where([v], v.asset_id == ^asset_id)
      |> select([v], v.variant)
      |> Repo.all()
      |> MapSet.new()

    Enum.reject(@valid_variants, &MapSet.member?(generated, &1))
  end

  @doc "Returns `true` when all configured variants have been generated."
  @spec fully_processed?(asset_id()) :: boolean()
  def fully_processed?(asset_id), do: missing_variants(asset_id) == []

  @doc "Deletes the asset and all its variant records."
  @spec delete_asset(asset_id()) :: :ok
  def delete_asset(asset_id) when is_binary(asset_id) do
    Repo.delete_all(from v in ImageVariant, where: v.asset_id == ^asset_id)
    Repo.delete_all(from a in ImageAsset, where: a.id == ^asset_id)
    :ok
  end

  @spec cdn_url(String.t()) :: String.t()
  defp cdn_url(storage_key), do: "#{@cdn_base_url}/#{storage_key}"
end
```
