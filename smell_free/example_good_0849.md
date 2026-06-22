```elixir
defmodule Content.PublishingWorkflow do
  @moduledoc """
  Orchestrates the multi-step content publishing workflow: editor review,
  SEO validation, asset optimisation check, and final publication. Each
  step is a discrete validation or mutation that reports success or a
  structured reason for rejection. The workflow stops at the first
  blocking failure but continues past warnings.
  """

  alias Content.{VersionedPageContext, SEOValidator, AssetAuditor}
  alias Audit.Trail

  @type page_id :: String.t()
  @type author_id :: String.t()
  @type publish_error ::
          :page_not_found
          | :missing_meta_description
          | :title_too_short
          | :unoptimised_assets
          | Ecto.Changeset.t()

  @type publish_result ::
          {:ok, %{page_id: page_id(), warnings: [String.t()]}}
          | {:error, publish_error()}

  @doc """
  Runs the full publishing checklist for `page_id` on behalf of `author_id`.
  Returns the published page ID and any non-blocking warnings, or a typed
  error when a blocking check fails.
  """
  @spec publish(page_id(), author_id()) :: publish_result()
  def publish(page_id, author_id) when is_binary(page_id) and is_binary(author_id) do
    with {:ok, version} <- fetch_draft_content(page_id),
         {:ok, seo_warnings} <- validate_seo(version),
         {:ok, asset_warnings} <- audit_assets(version),
         {:ok, page} <- do_publish(page_id, version, author_id) do
      all_warnings = seo_warnings ++ asset_warnings
      record_publication(page_id, author_id, all_warnings)
      {:ok, %{page_id: page.id, warnings: all_warnings}}
    end
  end

  defp fetch_draft_content(page_id) do
    case VersionedPageContext.fetch_live(page_id) do
      {:ok, version} -> {:ok, version}
      {:error, :not_found} -> {:error, :page_not_found}
    end
  end

  defp validate_seo(version) do
    warnings = []

    case SEOValidator.check(version) do
      {:ok, seo_warnings} ->
        {:ok, warnings ++ seo_warnings}

      {:error, :missing_meta_description} ->
        {:error, :missing_meta_description}

      {:error, :title_too_short} ->
        {:error, :title_too_short}
    end
  end

  defp audit_assets(version) do
    case AssetAuditor.audit(version) do
      {:ok, :all_optimised} ->
        {:ok, []}

      {:ok, :some_unoptimised, paths} ->
        warnings = Enum.map(paths, fn p -> "Unoptimised asset: #{p}" end)
        {:ok, warnings}

      {:error, :blocking_assets} ->
        {:error, :unoptimised_assets}
    end
  end

  defp do_publish(page_id, _version, author_id) do
    page = MyApp.Repo.get!(Content.Page, page_id)
    VersionedPageContext.publish(page, page.title, page.draft_body || "")
  end

  defp record_publication(page_id, author_id, warnings) do
    Trail.log(%{
      actor_id: author_id,
      action: "page_published",
      resource_type: "Page",
      resource_id: page_id,
      metadata: %{warning_count: length(warnings)},
      ip_address: nil
    })
  end
end
```
