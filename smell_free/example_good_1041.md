```elixir
defmodule CMS.Content.ArticleContext do
  @moduledoc """
  Provides the public interface for managing articles in the CMS.
  All database interactions are encapsulated here; callers depend only
  on this module rather than reaching into `Repo` or schema internals.
  """

  import Ecto.Query, warn: false

  alias CMS.Repo
  alias CMS.Content.{Article, ArticleFilter, Slug}

  @type create_attrs :: %{
          required(:title) => String.t(),
          required(:body) => String.t(),
          required(:author_id) => pos_integer(),
          optional(:tags) => [String.t()],
          optional(:published_at) => DateTime.t()
        }

  @type update_attrs :: %{
          optional(:title) => String.t(),
          optional(:body) => String.t(),
          optional(:tags) => [String.t()],
          optional(:published_at) => DateTime.t()
        }

  @doc """
  Returns a paginated list of published articles matching the given filter.
  """
  @spec list_published(ArticleFilter.t()) :: [Article.t()]
  def list_published(%ArticleFilter{} = filter) do
    Article
    |> where([a], not is_nil(a.published_at))
    |> apply_tag_filter(filter.tags)
    |> apply_author_filter(filter.author_id)
    |> order_by([a], desc: a.published_at)
    |> limit(^filter.page_size)
    |> offset(^((filter.page - 1) * filter.page_size))
    |> Repo.all()
  end

  @doc """
  Fetches a single article by its slug. Returns `{:error, :not_found}` when absent.
  """
  @spec get_by_slug(String.t()) :: {:ok, Article.t()} | {:error, :not_found}
  def get_by_slug(slug) when is_binary(slug) do
    case Repo.get_by(Article, slug: slug) do
      nil -> {:error, :not_found}
      article -> {:ok, article}
    end
  end

  @doc """
  Creates a new article. Returns `{:ok, article}` or `{:error, changeset}`.
  """
  @spec create(create_attrs()) :: {:ok, Article.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    attrs_with_slug = Map.put_new_lazy(attrs, :slug, fn -> Slug.generate(attrs[:title] || "") end)

    %Article{}
    |> Article.changeset(attrs_with_slug)
    |> Repo.insert()
  end

  @doc """
  Updates an existing article. Returns `{:ok, article}` or `{:error, changeset}`.
  """
  @spec update(Article.t(), update_attrs()) :: {:ok, Article.t()} | {:error, Ecto.Changeset.t()}
  def update(%Article{} = article, attrs) when is_map(attrs) do
    article
    |> Article.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Publishes an article by setting `published_at` to the current UTC time.
  """
  @spec publish(Article.t()) :: {:ok, Article.t()} | {:error, Ecto.Changeset.t()}
  def publish(%Article{published_at: nil} = article) do
    update(article, %{published_at: DateTime.utc_now()})
  end

  def publish(%Article{} = article), do: {:ok, article}

  @doc """
  Deletes an article permanently. Returns `{:ok, article}` or `{:error, changeset}`.
  """
  @spec delete(Article.t()) :: {:ok, Article.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Article{} = article), do: Repo.delete(article)

  # ---------------------------------------------------------------------------
  # Private query builders
  # ---------------------------------------------------------------------------

  @spec apply_tag_filter(Ecto.Query.t(), [String.t()] | nil) :: Ecto.Query.t()
  defp apply_tag_filter(query, nil), do: query
  defp apply_tag_filter(query, []), do: query

  defp apply_tag_filter(query, tags) when is_list(tags) do
    where(query, [a], fragment("? && ?", a.tags, ^tags))
  end

  @spec apply_author_filter(Ecto.Query.t(), pos_integer() | nil) :: Ecto.Query.t()
  defp apply_author_filter(query, nil), do: query

  defp apply_author_filter(query, author_id) when is_integer(author_id) do
    where(query, [a], a.author_id == ^author_id)
  end
end
```
