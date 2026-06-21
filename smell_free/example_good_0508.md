```elixir
defmodule MyApp.Knowledge.SearchIndex do
  @moduledoc """
  Maintains a full-text search index over knowledge-base articles using
  PostgreSQL's native `tsvector` / `tsquery` support. Indexing is
  performed on insert and update via database triggers; this module
  handles query construction, ranking, and result hydration.

  All search functions are read-only and safe to call from any context
  without supervision.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Knowledge.Article

  @default_limit 20
  @max_limit 100
  @rank_config "ts_rank_cd(search_vector, plainto_tsquery('english', $1), 4)"

  @type search_result :: %{
          article: Article.t(),
          rank: float(),
          headline: String.t() | nil
        }

  @doc """
  Searches knowledge-base articles for `query_text`. Returns results
  ordered by relevance rank with an optional highlighted headline snippet.
  """
  @spec search(String.t(), keyword()) :: [search_result()]
  def search(query_text, opts \\ []) when is_binary(query_text) and byte_size(query_text) > 0 do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit)
    category_slug = Keyword.get(opts, :category)
    with_headline = Keyword.get(opts, :headline, true)

    Article
    |> where([a], a.published == true)
    |> where([a], fragment("search_vector @@ plainto_tsquery('english', ?)", ^query_text))
    |> maybe_filter_category(category_slug)
    |> order_by([a], desc: fragment(@rank_config, ^query_text))
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn article ->
      headline = if with_headline, do: generate_headline(article, query_text), else: nil
      rank = compute_rank(article, query_text)
      %{article: article, rank: rank, headline: headline}
    end)
  end

  @doc "Returns articles in the same category as `article`, ordered by recency."
  @spec related(Article.t(), pos_integer()) :: [Article.t()]
  def related(%Article{} = article, limit \\ 5) when is_integer(limit) and limit > 0 do
    Article
    |> where([a], a.category_slug == ^article.category_slug)
    |> where([a], a.id != ^article.id)
    |> where([a], a.published == true)
    |> order_by([a], desc: a.published_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Increments the view count for `article_id` without loading the record."
  @spec record_view(String.t()) :: :ok
  def record_view(article_id) when is_binary(article_id) do
    Article
    |> where([a], a.id == ^article_id)
    |> Repo.update_all(inc: [view_count: 1])

    :ok
  end

  @spec maybe_filter_category(Ecto.Query.t(), String.t() | nil) :: Ecto.Query.t()
  defp maybe_filter_category(q, nil), do: q

  defp maybe_filter_category(q, slug) when is_binary(slug),
    do: where(q, [a], a.category_slug == ^slug)

  @spec generate_headline(Article.t(), String.t()) :: String.t() | nil
  defp generate_headline(article, query_text) do
    sql = """
    SELECT ts_headline('english', $1,
      plainto_tsquery('english', $2),
      'MaxWords=35, MinWords=15, ShortWord=3, MaxFragments=2')
    """

    case Repo.query(sql, [article.body, query_text]) do
      {:ok, %{rows: [[headline]]}} -> headline
      _ -> nil
    end
  end

  @spec compute_rank(Article.t(), String.t()) :: float()
  defp compute_rank(article, query_text) do
    sql = "SELECT ts_rank_cd(search_vector, plainto_tsquery('english', $1), 4) FROM articles WHERE id = $2"

    case Repo.query(sql, [query_text, article.id]) do
      {:ok, %{rows: [[rank]]}} -> rank || 0.0
      _ -> 0.0
    end
  end
end
```
