```elixir
defmodule Platform.FullTextSearch do
  @moduledoc """
  Full-text search context backed by PostgreSQL `tsvector` columns.

  Participating schemas must define a `search_vector` column of type
  `:tsvector` kept current by a database trigger or Ecto changeset hook.
  Results are ranked by relevance and optionally enriched with preloads.
  """

  import Ecto.Query, only: [from: 2]
  alias Platform.Repo

  @type language :: String.t()
  @type search_opts :: [
          limit: pos_integer(),
          language: language(),
          min_rank: float(),
          preload: [atom()]
        ]

  @type result(schema) :: %{record: schema, rank: float()}

  @doc """
  Performs a ranked full-text search against `schema`.
  Returns results ordered by descending relevance rank.
  """
  @spec search(module(), String.t(), search_opts()) :: [result(struct())]
  def search(schema, query_string, opts \\ []) when is_atom(schema) and is_binary(query_string) do
    normalized = normalize(query_string)

    if normalized == "" do
      []
    else
      opts |> build_query(schema, normalized) |> Repo.all() |> maybe_preload(opts)
    end
  end

  @doc """
  Returns the total count of matching records for pagination metadata.
  """
  @spec count(module(), String.t(), keyword()) :: non_neg_integer()
  def count(schema, query_string, opts \\ []) when is_atom(schema) do
    language = Keyword.get(opts, :language, "english")
    normalized = normalize(query_string)

    if normalized == "" do
      0
    else
      from(r in schema,
        where: fragment("? @@ plainto_tsquery(?, ?)", r.search_vector, ^language, ^normalized),
        select: count(r.id)
      )
      |> Repo.one()
    end
  end

  @doc """
  Builds a `tsvector` from a plain string for use in changeset hooks.
  Suitable for populating the `search_vector` column on insert/update.
  """
  @spec build_vector(String.t(), language()) :: Ecto.Query.t()
  def build_vector(content, language \\ "english") when is_binary(content) do
    from(x in fragment("SELECT to_tsvector(?, ?) AS v", ^language, ^content), select: x.v)
  end

  defp build_query(opts, schema, normalized) do
    language = Keyword.get(opts, :language, "english")
    limit = Keyword.get(opts, :limit, 20)
    min_rank = Keyword.get(opts, :min_rank, 0.01)

    from(r in schema,
      where: fragment("? @@ plainto_tsquery(?, ?)", r.search_vector, ^language, ^normalized),
      where:
        fragment(
          "ts_rank(?, plainto_tsquery(?, ?)) >= ?",
          r.search_vector,
          ^language,
          ^normalized,
          ^min_rank
        ),
      select: %{
        record: r,
        rank:
          fragment(
            "ts_rank(?, plainto_tsquery(?, ?))",
            r.search_vector,
            ^language,
            ^normalized
          )
      },
      order_by: [
        desc:
          fragment(
            "ts_rank(?, plainto_tsquery(?, ?))",
            r.search_vector,
            ^language,
            ^normalized
          )
      ],
      limit: ^limit
    )
  end

  defp maybe_preload(results, opts) do
    case Keyword.get(opts, :preload, []) do
      [] ->
        results

      preloads ->
        records = Enum.map(results, & &1.record)
        loaded = Repo.preload(records, preloads)
        Enum.zip_with(results, loaded, fn result, record -> %{result | record: record} end)
    end
  end

  defp normalize(raw) do
    raw
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^\w\s\-]/, " ")
    |> String.trim()
  end
end
```
