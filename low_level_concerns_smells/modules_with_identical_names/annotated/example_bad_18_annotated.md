# Annotated Example 18 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with Identical Names
- **Expected smell location:** Two separate files both define `CMS.Article`
- **Affected functions:** `CMS.Article.publish/2` (file one) and `CMS.Article.archive/2` (file two)
- **Explanation:** `CMS.Article` is defined in `lib/cms/article.ex` and again in `lib/cms/article_archival.ex`. Because BEAM uses module name as a unique key, the second-compiled file overwrites the first. Either publishing or archival logic will be unreachable, breaking the content editorial workflow.

---

```elixir
# ── file: lib/cms/article.ex ──────────────────────────────────────────────────

defmodule CMS.Article do
  @moduledoc """
  Manages article creation, editing, and publication workflows for the
  content management system. Used by editors and the scheduled publish queue.
  """

  alias CMS.{Author, Taxonomy, SEOAnalyser, CDNInvalidator, Repo}

  @max_title_length 200
  @max_slug_length 100
  @publishable_statuses [:draft, :review_approved]

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          slug: String.t(),
          body: String.t(),
          excerpt: String.t() | nil,
          author_id: String.t(),
          category_ids: [String.t()],
          tag_ids: [String.t()],
          status: :draft | :in_review | :review_approved | :published | :archived,
          seo_title: String.t() | nil,
          seo_description: String.t() | nil,
          published_at: DateTime.t() | nil,
          scheduled_for: DateTime.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  defstruct [
    :id,
    :title,
    :slug,
    :body,
    :excerpt,
    :author_id,
    :seo_title,
    :seo_description,
    :published_at,
    :scheduled_for,
    :created_at,
    :updated_at,
    category_ids: [],
    tag_ids: [],
    status: :draft
  ]

  # VALIDATION: SMELL START - Modules with Identical Names
  # VALIDATION: This is a smell because `CMS.Article` is defined again in
  # `lib/cms/article_archival.ex`. BEAM replaces the first loaded definition
  # with the second. `publish/2` will disappear if the archival file wins,
  # preventing any article from being published in the CMS.

  @spec publish(String.t(), map()) :: {:ok, t()} | {:error, term()}
  def publish(article_id, attrs \\ %{}) do
    with {:ok, article} <- Repo.fetch(:articles, article_id),
         :ok <- validate_publishable(article),
         {:ok, _seo} <- SEOAnalyser.check(article) do
      now = DateTime.utc_now()
      publish_time = Map.get(attrs, :publish_at, now)

      changes = %{
        status: :published,
        published_at: publish_time,
        seo_title: Map.get(attrs, :seo_title, article.seo_title),
        seo_description: Map.get(attrs, :seo_description, article.seo_description),
        updated_at: now
      }

      updated = Repo.update(:articles, article_id, changes)

      CDNInvalidator.purge(article.slug)

      {:ok, updated}
    end
  end

  # VALIDATION: SMELL END

  @spec create(map()) :: {:ok, t()} | {:error, term()}
  def create(attrs) do
    with :ok <- validate_title(attrs[:title]),
         {:ok, slug} <- generate_slug(attrs[:title], attrs[:slug]),
         {:ok, _author} <- Author.fetch(attrs[:author_id]) do
      now = DateTime.utc_now()

      article = %__MODULE__{
        id: generate_id(),
        title: attrs[:title],
        slug: slug,
        body: attrs[:body] || "",
        excerpt: attrs[:excerpt],
        author_id: attrs[:author_id],
        category_ids: attrs[:category_ids] || [],
        tag_ids: attrs[:tag_ids] || [],
        seo_title: attrs[:seo_title],
        seo_description: attrs[:seo_description],
        created_at: now,
        updated_at: now
      }

      Repo.insert(:articles, article)
      Taxonomy.index(article)

      {:ok, article}
    end
  end

  @spec submit_for_review(String.t()) :: {:ok, map()} | {:error, term()}
  def submit_for_review(article_id) do
    with {:ok, article} <- Repo.fetch(:articles, article_id),
         :ok <- validate_draft(article) do
      updated = Repo.update(:articles, article_id, %{status: :in_review, updated_at: DateTime.utc_now()})
      {:ok, updated}
    end
  end

  defp validate_publishable(%{status: s}) when s in @publishable_statuses, do: :ok
  defp validate_publishable(_), do: {:error, :article_not_ready_to_publish}

  defp validate_draft(%{status: :draft}), do: :ok
  defp validate_draft(_), do: {:error, :article_not_a_draft}

  defp validate_title(t) when is_binary(t) and byte_size(t) <= @max_title_length, do: :ok
  defp validate_title(_), do: {:error, :invalid_title}

  defp generate_slug(title, nil) do
    slug = title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
    {:ok, String.slice(slug, 0, @max_slug_length)}
  end

  defp generate_slug(_, slug), do: {:ok, slug}

  defp generate_id, do: :crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)
end


# ── file: lib/cms/article_archival.ex ────────────────────────────────────────

defmodule CMS.Article do
  @moduledoc """
  Handles article archival, restoration, and permanent deletion workflows.
  Manages content retirement policies and editorial cleanup operations.
  """

  alias CMS.{CDNInvalidator, SearchIndex, Repo, AuditLog}

  @archive_retention_days 365

  @spec archive(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def archive(article_id, opts \\ %{}) do
    reason = Map.get(opts, :reason, "manually archived")

    with {:ok, article} <- Repo.fetch(:articles, article_id),
         :ok <- validate_archivable(article) do
      now = DateTime.utc_now()

      updated = Repo.update(:articles, article_id, %{
        status: :archived,
        archived_at: now,
        archive_reason: reason,
        delete_after: Date.add(Date.utc_today(), @archive_retention_days),
        updated_at: now
      })

      SearchIndex.remove(article_id)

      if article.status == :published do
        CDNInvalidator.purge(article.slug)
      end

      AuditLog.write(:article_archived, %{article_id: article_id, reason: reason})

      {:ok, updated}
    end
  end

  @spec restore(String.t()) :: {:ok, map()} | {:error, term()}
  def restore(article_id) do
    with {:ok, article} <- Repo.fetch(:articles, article_id),
         :ok <- validate_archived(article) do
      updated = Repo.update(:articles, article_id, %{
        status: :draft,
        archived_at: nil,
        archive_reason: nil,
        delete_after: nil,
        updated_at: DateTime.utc_now()
      })

      AuditLog.write(:article_restored, %{article_id: article_id})

      {:ok, updated}
    end
  end

  @spec permanently_delete(String.t()) :: :ok | {:error, term()}
  def permanently_delete(article_id) do
    with {:ok, article} <- Repo.fetch(:articles, article_id),
         :ok <- validate_archived(article) do
      Repo.delete(:articles, article_id)
      SearchIndex.remove(article_id)
      AuditLog.write(:article_permanently_deleted, %{article_id: article_id})
      :ok
    end
  end

  defp validate_archivable(%{status: :archived}), do: {:error, :already_archived}
  defp validate_archivable(_), do: :ok

  defp validate_archived(%{status: :archived}), do: :ok
  defp validate_archived(_), do: {:error, :not_archived}
end
```
