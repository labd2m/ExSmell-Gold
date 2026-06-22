# File: `example_good_1035.md`

```elixir
defmodule Catalog.SearchSuggestion do
  @moduledoc """
  Provides ranked search suggestions by combining prefix matching against
  a product catalog with historical search frequency data.

  Suggestions blend catalog relevance (product name prefix match) with
  popularity (how often a query has been searched), allowing recently
  trending queries to surface alongside exact catalog matches.
  """

  import Ecto.Query, warn: false

  alias Catalog.{Product, Repo, SearchLog}

  @type suggestion :: %{
          text: String.t(),
          source: :catalog | :history,
          score: float()
        }

  @type suggest_opts :: [
          limit: pos_integer(),
          catalog_weight: float(),
          history_weight: float(),
          min_history_count: pos_integer()
        ]

  @doc """
  Returns ranked search suggestions for `prefix`.

  Suggestions come from two sources:
  - Catalog: product names starting with `prefix`
  - History: previously searched queries starting with `prefix`

  Both sources are blended by weighted score and deduplicated.

  Options:
  - `:limit` — maximum suggestions to return (default: 8)
  - `:catalog_weight` — score weight for catalog matches (default: 1.0)
  - `:history_weight` — score weight for historical matches (default: 1.5)
  - `:min_history_count` — minimum search count to include a history entry (default: 2)
  """
  @spec suggest(String.t(), suggest_opts()) :: [suggestion()]
  def suggest(prefix, opts \\ []) when is_binary(prefix) and byte_size(prefix) > 0 do
    limit = Keyword.get(opts, :limit, 8)
    catalog_weight = Keyword.get(opts, :catalog_weight, 1.0)
    history_weight = Keyword.get(opts, :history_weight, 1.5)
    min_history = Keyword.get(opts, :min_history_count, 2)

    catalog_suggestions = fetch_catalog_suggestions(prefix, catalog_weight, limit)
    history_suggestions = fetch_history_suggestions(prefix, history_weight, min_history, limit)

    (catalog_suggestions ++ history_suggestions)
    |> deduplicate_and_merge()
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Records a search query in the history log.

  Call this whenever a user submits a search so that query frequencies
  stay current. Returns `:ok`.
  """
  @spec record_search(String.t()) :: :ok
  def record_search(query) when is_binary(query) and byte_size(query) > 0 do
    normalised = String.downcase(String.trim(query))

    SearchLog
    |> where([s], s.query == ^normalised)
    |> Repo.one()
    |> case do
      nil ->
        %{query: normalised, count: 1, last_searched_at: DateTime.utc_now()}
        |> SearchLog.changeset()
        |> Repo.insert()

      existing ->
        existing
        |> SearchLog.increment_changeset(%{
          count: existing.count + 1,
          last_searched_at: DateTime.utc_now()
        })
        |> Repo.update()
    end

    :ok
  end

  @doc """
  Returns the top `n` most-searched queries across all time.
  """
  @spec trending(pos_integer()) :: [%{query: String.t(), count: non_neg_integer()}]
  def trending(n) when is_integer(n) and n > 0 do
    SearchLog
    |> order_by([s], desc: s.count)
    |> limit(^n)
    |> select([s], %{query: s.query, count: s.count})
    |> Repo.all()
  end

  defp fetch_catalog_suggestions(prefix, weight, limit) do
    pattern = "#{sanitize(prefix)}%"

    Product
    |> where([p], ilike(p.name, ^pattern) and p.active == true)
    |> order_by([p], asc: p.name)
    |> limit(^limit)
    |> select([p], p.name)
    |> Repo.all()
    |> Enum.map(fn name ->
      %{text: name, source: :catalog, score: weight * name_match_score(name, prefix)}
    end)
  end

  defp fetch_history_suggestions(prefix, weight, min_count, limit) do
    pattern = "#{sanitize(prefix)}%"

    SearchLog
    |> where([s], ilike(s.query, ^pattern) and s.count >= ^min_count)
    |> order_by([s], desc: s.count)
    |> limit(^limit)
    |> select([s], %{query: s.query, count: s.count})
    |> Repo.all()
    |> Enum.map(fn %{query: query, count: count} ->
      popularity_score = :math.log(count + 1)
      %{text: query, source: :history, score: weight * popularity_score}
    end)
  end

  defp deduplicate_and_merge(suggestions) do
    suggestions
    |> Enum.group_by(&String.downcase(&1.text))
    |> Enum.map(fn {_key, dupes} ->
      best = Enum.max_by(dupes, & &1.score)
      merged_score = Enum.sum(Enum.map(dupes, & &1.score))
      %{best | score: Float.round(merged_score, 4)}
    end)
  end

  defp name_match_score(name, prefix) do
    prefix_len = String.length(prefix)
    name_len = String.length(name)
    if name_len > 0, do: prefix_len / name_len, else: 0.0
  end

  defp sanitize(text) do
    String.replace(text, ~r/[%_\\]/, "")
  end
end
```
