```elixir
defmodule CMS.ContentPublisher do
  @moduledoc """
  Manages the content publishing workflow for CMS articles.

  Coordinates draft validation, scheduled publishing, and content version
  snapshotting. Published articles are immutable version snapshots; edits
  always produce a new draft version.
  """

  alias CMS.{Article, ArticleVersion, Repo}
  alias Ecto.Multi

  @type publish_result ::
          {:ok, ArticleVersion.t()}
          | {:error, :article_not_found}
          | {:error, :not_in_draft_state}
          | {:error, :content_validation_failed, [String.t()]}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Publishes the current draft version of an article.

  Creates an immutable version snapshot and transitions the article state to
  `:published`. Returns the version record on success.
  """
  @spec publish(Ecto.UUID.t(), String.t()) :: publish_result()
  def publish(article_id, published_by) when is_binary(article_id) and is_binary(published_by) do
    with {:ok, article} <- fetch_draft_article(article_id),
         :ok <- validate_content(article),
         {:ok, result} <- persist_publication(article, published_by) do
      {:ok, result.version}
    end
  end

  @doc """
  Reverts a published article to draft state, incrementing its draft version number.
  """
  @spec revert_to_draft(Ecto.UUID.t()) ::
          {:ok, Article.t()} | {:error, :article_not_found} | {:error, :not_published}
  def revert_to_draft(article_id) when is_binary(article_id) do
    with {:ok, article} <- fetch_published_article(article_id) do
      article
      |> Article.changeset(%{
        status: :draft,
        draft_version: article.published_version + 1
      })
      |> Repo.update()
    end
  end

  defp fetch_draft_article(article_id) do
    case Repo.get(Article, article_id) do
      nil -> {:error, :article_not_found}
      %Article{status: :published} -> {:error, :not_in_draft_state}
      article -> {:ok, article}
    end
  end

  defp fetch_published_article(article_id) do
    case Repo.get(Article, article_id) do
      nil -> {:error, :article_not_found}
      %Article{status: :draft} -> {:error, :not_published}
      article -> {:ok, article}
    end
  end

  defp validate_content(%Article{} = article) do
    errors =
      []
      |> check_title(article)
      |> check_body_length(article)
      |> check_slug_format(article)

    case errors do
      [] -> :ok
      reasons -> {:error, :content_validation_failed, reasons}
    end
  end

  defp check_title(errors, %{title: title}) when is_binary(title) and byte_size(title) >= 5 do
    errors
  end

  defp check_title(errors, _article), do: ["Title must be at least 5 characters" | errors]

  defp check_body_length(errors, %{body: body}) when is_binary(body) and byte_size(body) >= 100 do
    errors
  end

  defp check_body_length(errors, _article), do: ["Body must be at least 100 characters" | errors]

  defp check_slug_format(errors, %{slug: slug}) when is_binary(slug) do
    if Regex.match?(~r/^[a-z0-9-]+$/, slug) do
      errors
    else
      ["Slug may only contain lowercase letters, numbers, and hyphens" | errors]
    end
  end

  defp check_slug_format(errors, _article), do: ["Slug is required" | errors]

  defp persist_publication(%Article{} = article, published_by) do
    Multi.new()
    |> Multi.update(:article, Article.changeset(article, %{
      status: :published,
      published_at: DateTime.utc_now(),
      published_version: article.draft_version
    }))
    |> Multi.insert(:version, fn %{article: updated} ->
      ArticleVersion.changeset(%ArticleVersion{}, %{
        article_id: updated.id,
        version_number: updated.published_version,
        title: updated.title,
        body: updated.body,
        published_by: published_by,
        published_at: updated.published_at
      })
    end)
    |> Repo.transaction()
  end
end
```
