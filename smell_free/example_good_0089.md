# File: `example_good_89.md`

```elixir
defmodule Search.QueryBuilder do
  @moduledoc """
  Composable Ecto query builder for the unified content search index.

  Each builder function accepts and returns an `Ecto.Query`, allowing
  callers to assemble search queries from discrete, independently
  testable clauses without hard-coding every combination into a single
  monolithic function.
  """

  import Ecto.Query

  alias Search.{IndexEntry, Repo}

  @type query :: Ecto.Query.t()
  @type sort_dir :: :asc | :desc

  @doc """
  Returns a base query over the search index for a specific content type.

  Must be called first; all other builder functions expect a query
  seeded by this function.
  """
  @spec for_type(String.t()) :: query()
  def for_type(content_type) when is_binary(content_type) do
    where(IndexEntry, [e], e.content_type == ^content_type and e.indexed == true)
  end

  @doc """
  Restricts results to entries whose title or body match the search terms
  using PostgreSQL full-text search.
  """
  @spec matching(query(), String.t()) :: query()
  def matching(query, text) when is_binary(text) and byte_size(text) > 0 do
    tsquery = to_tsquery(text)
    where(query, [e], fragment("to_tsvector('english', ? || ' ' || ?) @@ to_tsquery('english', ?)", e.title, e.body, ^tsquery))
  end

  def matching(query, _empty), do: query

  @doc """
  Filters entries by one or more tag values.

  When `tags` is an empty list the query is returned unchanged.
  """
  @spec tagged_with(query(), [String.t()]) :: query()
  def tagged_with(query, []), do: query

  def tagged_with(query, tags) when is_list(tags) do
    where(query, [e], fragment("? && ?", e.tags, ^tags))
  end

  @doc """
  Restricts results to entries authored by a specific user.
  """
  @spec by_author(query(), String.t()) :: query()
  def by_author(query, author_id) when is_binary(author_id) do
    where(query, [e], e.author_id == ^author_id)
  end

  @doc """
  Restricts results to entries published within a date range.

  Either bound may be `nil` to leave that end open.
  """
  @spec published_between(query(), DateTime.t() | nil, DateTime.t() | nil) :: query()
  def published_between(query, from, until) do
    query
    |> apply_lower_bound(from)
    |> apply_upper_bound(until)
  end

  @doc """
  Sorts results by a named field in the given direction.
  """
  @spec sort(query(), :published_at | :title | :relevance, sort_dir()) :: query()
  def sort(query, :published_at, :asc), do: order_by(query, [e], asc: e.published_at)
  def sort(query, :published_at, :desc), do: order_by(query, [e], desc: e.published_at)
  def sort(query, :title, :asc), do: order_by(query, [e], asc: e.title)
  def sort(query, :title, :desc), do: order_by(query, [e], desc: e.title)
  def sort(query, :relevance, _dir), do: query

  @doc """
  Applies pagination to a query.
  """
  @spec paginate(query(), pos_integer(), pos_integer()) :: query()
  def paginate(query, page, per_page)
      when is_integer(page) and page > 0 and is_integer(per_page) and per_page > 0 do
    query
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
  end

  @doc """
  Executes the assembled query and returns a list of matching entries.
  """
  @spec execute(query()) :: [IndexEntry.t()]
  def execute(query) do
    Repo.all(query)
  end

  @doc """
  Executes the assembled query and returns the total count of matching entries
  without applying any pagination limit or offset.
  """
  @spec count(query()) :: non_neg_integer()
  def count(query) do
    query
    |> exclude(:order_by)
    |> exclude(:limit)
    |> exclude(:offset)
    |> Repo.aggregate(:count, :id)
  end

  defp apply_lower_bound(query, nil), do: query

  defp apply_lower_bound(query, from) do
    where(query, [e], e.published_at >= ^from)
  end

  defp apply_upper_bound(query, nil), do: query

  defp apply_upper_bound(query, until) do
    where(query, [e], e.published_at <= ^until)
  end

  defp to_tsquery(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&sanitize_term/1)
    |> Enum.join(" & ")
  end

  defp sanitize_term(term) do
    term
    |> String.replace(~r/[^a-zA-Z0-9\-]/, "")
    |> String.downcase()
  end
end
```
