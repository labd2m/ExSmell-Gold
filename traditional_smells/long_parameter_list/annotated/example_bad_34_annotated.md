# Annotated Example 34 — Long Parameter List

## Metadata

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `CMS.Articles.publish_article/11` |
| **Affected function(s)** | `publish_article/11` |
| **Explanation** | The function accepts 11 individual parameters covering authorship (author_id, author_name), content (title, body, excerpt, cover_image_url), taxonomy (category, tags), SEO metadata (meta_title, meta_description), and delivery (notify_subscribers). These map naturally to a `%ArticleContent{}`, `%SEOMeta{}`, and `%PublishOptions{}` struct rather than eleven separate positional arguments. |

---

```elixir
# VALIDATION: SMELL START - Long Parameter List
# VALIDATION: This is a smell because `publish_article/11` accepts eleven
# individual positional parameters. Author data (author_id, author_name),
# article content (title, body, excerpt, cover_image_url), taxonomy info
# (category, tags), SEO fields (meta_title, meta_description), and a
# delivery option (notify_subscribers) are all threaded through one
# flat signature. Beyond being hard to read, the presence of two separate
# "title"-like strings (title vs meta_title) adjacent in the list is an
# accident waiting to happen.
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
# VALIDATION: SMELL END
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
