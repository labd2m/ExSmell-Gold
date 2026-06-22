```elixir
defmodule Support.KnowledgeBaseSearch do
  @moduledoc """
  Searches the support knowledge base using a combination of keyword
  matching and category filtering. Articles are ranked by relevance score
  computed from term frequency in the title and body. The module reads
  from ETS for sub-millisecond hot-path queries and refreshes the index
  from the database on a configurable schedule.
  """

  use GenServer

  require Logger

  @table :kb_search_index
  @refresh_interval_ms :timer.minutes(10)

  @type article_id :: String.t()
  @type article :: %{
          id: article_id(),
          title: String.t(),
          body: String.t(),
          category: String.t(),
          published: boolean()
        }

  @type search_result :: %{article: article(), score: float()}

  @doc "Starts the knowledge base search service."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\\\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Searches published articles for `query`. Optionally filters by `category`.
  Returns results sorted by relevance score descending.
  """
  @spec search(String.t(), keyword()) :: [search_result()]
  def search(query, opts \\\\ []) when is_binary(query) do
    category = Keyword.get(opts, :category)
    limit = Keyword.get(opts, :limit, 10)
    terms = query |> String.downcase() |> String.split(~r/\s+/, trim: true)

    :ets.tab2list(@table)
    |> Enum.filter(fn {_id, article} ->
      article.published and (is_nil(category) or article.category == category)
    end)
    |> Enum.map(fn {_id, article} -> %{article: article, score: score(article, terms)} end)
    |> Enum.filter(fn %{score: s} -> s > 0.0 end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  @doc "Fetches a single article by ID from the index."
  @spec fetch(article_id()) :: {:ok, article()} | {:error, :not_found}
  def fetch(article_id) when is_binary(article_id) do
    case :ets.lookup(@table, article_id) do
      [{^article_id, article}] -> {:ok, article}
      [] -> {:error, :not_found}
    end
  end

  @doc "Forces an immediate index refresh from the database."
  @spec refresh() :: :ok
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    interval = Keyword.get(opts, :refresh_interval_ms, @refresh_interval_ms)
    send(self(), :load)
    Process.send_after(self(), :refresh, interval)
    {:ok, %{interval: interval}}
  end

  @impl GenServer
  def handle_cast(:refresh, state), do: load_articles(state)

  @impl GenServer
  def handle_info(:load, state), do: load_articles(state)

  def handle_info(:refresh, %{interval: interval} = state) do
    load_articles(state)
    Process.send_after(self(), :refresh, interval)
    {:noreply, state}
  end

  defp load_articles(state) do
    import Ecto.Query

    articles =
      from(a in "kb_articles", where: a.published == true, select: map(a, [:id, :title, :body, :category, :published]))
      |> MyApp.Repo.all()

    :ets.delete_all_objects(@table)
    Enum.each(articles, fn a -> :ets.insert(@table, {a.id, atomise_keys(a)}) end)
    Logger.debug("[KBSearch] Index refreshed with #{length(articles)} article(s)")
    {:noreply, state}
  rescue
    e ->
      Logger.error("[KBSearch] Refresh failed: #{Exception.message(e)}")
      {:noreply, state}
  end

  defp score(article, terms) do
    title_lower = String.downcase(article.title)
    body_lower = String.downcase(article.body)

    Enum.reduce(terms, 0.0, fn term, acc ->
      title_hits = count_occurrences(title_lower, term) * 3.0
      body_hits = count_occurrences(body_lower, term) * 1.0
      acc + title_hits + body_hits
    end)
  end

  defp count_occurrences(text, term) do
    text |> String.split(term) |> length() |> Kernel.-(1) |> max(0)
  end

  defp atomise_keys(map) do
    Map.new(map, fn {k, v} -> {if(is_binary(k), do: String.to_existing_atom(k), else: k), v} end)
  rescue
    _ -> map
  end
end
```
