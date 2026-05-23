```elixir
defmodule CMS.Articles do
  @moduledoc """
  Handles article creation, slug generation, full-text indexing,
  and subscriber notification for the content management system.
  """

  require Logger

  alias CMS.Repo
  alias CMS.Schemas.Article
  alias CMS.Schemas.ArticleRevision
  alias CMS.SlugGenerator
  alias CMS.SearchIndex
  alias CMS.Mailer

  @valid_categories ~w(technology business health science culture sports)
  @max_tags 10
  @min_body_length 200

  def publish_article(
        author_id,
        author_name,
        title,
        body,
        excerpt,
        cover_image_url,
        category,
        tags,
        meta_title,
        meta_description,
        notify_subscribers
      ) do
    with :ok <- validate_title(title),
         :ok <- validate_body(body),
         :ok <- validate_category(category),
         :ok <- validate_tags(tags) do
      slug = SlugGenerator.generate(title)
      effective_meta_title = meta_title || title
      effective_excerpt = excerpt || String.slice(body, 0, 200)

      article_attrs = %{
        author_id: author_id,
        author_name: author_name,
        title: String.trim(title),
        slug: slug,
        body: body,
        excerpt: effective_excerpt,
        cover_image_url: cover_image_url,
        category: category,
        tags: tags || [],
        meta_title: effective_meta_title,
        meta_description: meta_description,
        status: :published,
        published_at: DateTime.utc_now(),
        inserted_at: DateTime.utc_now()
      }

      case Repo.insert(Article.changeset(%Article{}, article_attrs)) do
        {:ok, article} ->
          Repo.insert!(ArticleRevision.changeset(%ArticleRevision{}, %{
            article_id: article.id,
            revision_number: 1,
            body: body,
            author_id: author_id,
            saved_at: DateTime.utc_now()
          }))

          SearchIndex.index_article(article)

          if notify_subscribers do
            Mailer.notify_subscribers(article, category)
            Logger.info("Subscriber notification queued for article #{article.id}")
          end

          Logger.info("Article #{article.id} published by #{author_id} in #{category}")
          {:ok, article}

        {:error, %{errors: [slug: _]}} ->
          {:error, :slug_conflict}

        {:error, changeset} ->
          Logger.error("Article publish failed: #{inspect(changeset.errors)}")
          {:error, :publish_failed}
      end
    end
  end

  defp validate_title(title) do
    if is_binary(title) and String.length(String.trim(title)) >= 5 do
      :ok
    else
      {:error, :title_too_short}
    end
  end

  defp validate_body(body) do
    if is_binary(body) and String.length(body) >= @min_body_length do
      :ok
    else
      {:error, :body_too_short}
    end
  end

  defp validate_category(c) when c in @valid_categories, do: :ok
  defp validate_category(c), do: {:error, {:unknown_category, c}}

  defp validate_tags(nil), do: :ok

  defp validate_tags(tags) when is_list(tags) do
    cond do
      length(tags) > @max_tags -> {:error, :too_many_tags}
      not Enum.all?(tags, &is_binary/1) -> {:error, :invalid_tag_format}
      true -> :ok
    end
  end

  defp validate_tags(_), do: {:error, :tags_must_be_list}
end
```
