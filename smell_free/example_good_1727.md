```elixir
defmodule Marketplace.ListingPublisher do
  @moduledoc """
  Coordinates the publication workflow for marketplace listings.

  A listing must pass moderation checks and image validation before
  it can be published. Each step is implemented as an isolated private
  function. The workflow is composed using `with` to ensure clean
  error propagation without ambiguous fallthrough clauses.
  """

  alias Marketplace.Listing
  alias Marketplace.ModerationService
  alias Marketplace.ImageValidator
  alias Marketplace.ListingStore
  alias Marketplace.SearchIndex

  @type publish_result ::
          {:ok, Listing.t()}
          | {:error, :moderation_rejected, String.t()}
          | {:error, :invalid_images, [String.t()]}
          | {:error, :persistence_failed}
          | {:error, :indexing_failed}

  @doc """
  Publishes a draft listing through the full publication pipeline.

  Steps: moderation check → image validation → persist status change →
  search index update. Any failure halts the pipeline and returns a
  descriptive error.
  """
  @spec publish(Listing.t()) :: publish_result()
  def publish(%Listing{status: :draft} = listing) do
    with {:ok, :approved} <- run_moderation(listing),
         :ok <- validate_images(listing),
         {:ok, published} <- persist_published(listing),
         :ok <- index_listing(published) do
      {:ok, published}
    end
  end

  def publish(%Listing{status: status}) do
    {:error, :invalid_status, "Expected :draft, got: #{status}"}
  end

  @spec run_moderation(Listing.t()) ::
          {:ok, :approved} | {:error, :moderation_rejected, String.t()}
  defp run_moderation(listing) do
    case ModerationService.review(listing) do
      {:approved, _score} ->
        {:ok, :approved}

      {:rejected, reason} ->
        {:error, :moderation_rejected, reason}
    end
  end

  @spec validate_images(Listing.t()) ::
          :ok | {:error, :invalid_images, [String.t()]}
  defp validate_images(%Listing{image_urls: image_urls}) do
    failures =
      image_urls
      |> Enum.map(&{&1, ImageValidator.validate(&1)})
      |> Enum.filter(fn {_url, result} -> result != :ok end)
      |> Enum.map(fn {url, _} -> url end)

    case failures do
      [] -> :ok
      failed_urls -> {:error, :invalid_images, failed_urls}
    end
  end

  @spec persist_published(Listing.t()) ::
          {:ok, Listing.t()} | {:error, :persistence_failed}
  defp persist_published(listing) do
    attrs = %{status: :published, published_at: DateTime.utc_now()}

    case ListingStore.update(listing, attrs) do
      {:ok, updated} -> {:ok, updated}
      {:error, _} -> {:error, :persistence_failed}
    end
  end

  @spec index_listing(Listing.t()) :: :ok | {:error, :indexing_failed}
  defp index_listing(listing) do
    case SearchIndex.upsert(listing) do
      :ok -> :ok
      {:error, _} -> {:error, :indexing_failed}
    end
  end
end
```
