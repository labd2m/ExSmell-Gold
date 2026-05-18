```elixir
defmodule CMS.ArticleIndexer do
  @moduledoc """
  Indexes published articles into the search and content discovery layer.
  Processes article metadata including categories, tags, and author information
  to build an inverted index for efficient content retrieval.
  """

  require Logger

  alias CMS.{ArticleRepo, SearchIndex, TagRegistry, AuthorCache, IndexAudit}

  @batch_size 50
  @index_version "v3"

  @spec index_all(keyword()) :: {:ok, map()} | {:error, term()}
  def index_all(opts \\ []) do
    since = Keyword.get(opts, :since)
    Logger.info("Starting full article index", since: since, version: @index_version)

    with {:ok, audit} <- IndexAudit.start(@index_version),
         {:ok, stats} <- stream_and_index(since),
         :ok <- IndexAudit.complete(audit.id, stats) do
      Logger.info("Article indexing complete", stats: inspect(stats))
      {:ok, stats}
    end
  end

  @spec index_one(String.t()) :: {:ok, map()} | {:error, term()}
  def index_one(article_id) do
    with {:ok, article} <- ArticleRepo.get_published(article_id),
         {:ok, doc} <- build_index_document(article),
         {:ok, _} <- SearchIndex.upsert(@index_version, article_id, doc) do
      {:ok, doc}
    end
  end

  defp stream_and_index(since) do
    ArticleRepo.stream_published(since: since, batch_size: @batch_size)
    |> Stream.map(&build_index_document/1)
    |> Stream.chunk_every(@batch_size)
    |> Enum.reduce({:ok, %{indexed: 0, failed: 0}}, fn batch, {:ok, stats} ->
      {oks, errs} =
        Enum.split_with(batch, &match?({:ok, _}, &1))

      case SearchIndex.bulk_upsert(@index_version, Enum.map(oks, fn {:ok, d} -> d end)) do
        :ok ->
          {:ok, %{stats | indexed: stats.indexed + length(oks), failed: stats.failed + length(errs)}}

        {:error, reason} ->
          Logger.error("Bulk upsert failed", reason: inspect(reason))
          {:ok, %{stats | failed: stats.failed + length(batch)}}
      end
    end)
  end

  defp build_index_document(%{id: id, title: title, body: body, tags: tags,
                               author_id: author_id, category: category,
                               published_at: published_at}) do
    with {:ok, author} <- AuthorCache.get(author_id),
         {:ok, tag_atoms} <- index_tags(tags) do
      doc = %{
        id: id,
        title: title,
        body_excerpt: excerpt(body, 300),
        author_name: author.display_name,
        author_slug: author.slug,
        category: category,
        tags: tag_atoms,
        published_at: DateTime.to_iso8601(published_at),
        indexed_at: DateTime.to_iso8601(DateTime.utc_now())
      }

      {:ok, doc}
    end
  end

  defp build_index_document(_), do: {:error, :malformed_article}

  defp index_tags(tags) when is_list(tags) do
    atoms = Enum.map(tags, &tag_to_atom/1)

    {:ok, atoms}
  end

  defp index_tags(_), do: {:ok, []}

  defp tag_to_atom(tag) when is_binary(tag) do
    tag
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, "_")
    |> String.to_atom()
  end

  defp tag_to_atom(tag), do: tag

  defp excerpt(body, max_length) when is_binary(body) do
    if String.length(body) <= max_length do
      body
    else
      body
      |> String.slice(0, max_length)
      |> String.trim_trailing()
      |> Kernel.<>("…")
    end
  end

  defp excerpt(_, _), do: ""
end
```
