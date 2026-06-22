```elixir
defmodule Crawler.Result do
  @moduledoc false

  @type t :: %__MODULE__{
          url: String.t(),
          status: non_neg_integer() | nil,
          depth: non_neg_integer(),
          links: [String.t()],
          error: term() | nil,
          fetched_at: DateTime.t()
        }

  defstruct [:url, :status, :depth, :error, :fetched_at, links: []]
end

defmodule Crawler do
  @moduledoc """
  A breadth-first web crawler with configurable concurrency, depth limit,
  and domain restriction.

  Each URL is fetched via `:httpc` and its links are extracted. The crawler
  respects a maximum depth so it does not traverse the entire web, and
  optionally restricts itself to a single host to avoid leaving the target
  domain. Already-visited URLs are deduplicated via a MapSet.
  """

  alias Crawler.Result

  @type opts :: [
          max_depth: pos_integer(),
          max_pages: pos_integer(),
          same_host_only: boolean(),
          timeout_ms: pos_integer(),
          max_concurrency: pos_integer()
        ]

  @spec crawl(String.t(), opts()) :: [Result.t()]
  def crawl(start_url, opts \\ []) when is_binary(start_url) do
    config = %{
      max_depth: Keyword.get(opts, :max_depth, 2),
      max_pages: Keyword.get(opts, :max_pages, 100),
      same_host_only: Keyword.get(opts, :same_host_only, true),
      timeout_ms: Keyword.get(opts, :timeout_ms, 5_000),
      max_concurrency: Keyword.get(opts, :max_concurrency, 5),
      start_host: URI.parse(start_url).host
    }

    do_crawl([{start_url, 0}], MapSet.new([start_url]), [], 0, config)
  end

  defp do_crawl([], _visited, results, _count, _config), do: Enum.reverse(results)
  defp do_crawl(_queue, _visited, results, count, %{max_pages: max}) when count >= max do
    Enum.reverse(results)
  end

  defp do_crawl(queue, visited, results, count, config) do
    {batch, remaining_queue} = Enum.split(queue, config.max_concurrency)

    batch_results =
      batch
      |> Task.async_stream(fn {url, depth} -> fetch(url, depth, config) end,
        timeout: config.timeout_ms + 1_000,
        max_concurrency: config.max_concurrency,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, _} -> nil
      end)
      |> Enum.reject(&is_nil/1)

    {new_queue, new_visited} =
      Enum.reduce(batch_results, {remaining_queue, visited}, fn result, {q, vis} ->
        if result.depth < config.max_depth do
          new_links = Enum.reject(result.links, &MapSet.member?(vis, &1))
          new_pairs = Enum.map(new_links, &{&1, result.depth + 1})
          new_vis = Enum.reduce(new_links, vis, &MapSet.put(&2, &1))
          {q ++ new_pairs, new_vis}
        else
          {q, vis}
        end
      end)

    do_crawl(new_queue, new_visited, batch_results ++ results, count + length(batch), config)
  end

  defp fetch(url, depth, config) do
    case :httpc.request(:get, {to_charlist(url), []}, [timeout: config.timeout_ms], []) do
      {:ok, {{_, status, _}, _headers, body}} ->
        links = if status in 200..299, do: extract_links(to_string(body), url, config), else: []
        %Result{url: url, status: status, depth: depth, links: links, fetched_at: DateTime.utc_now()}

      {:error, reason} ->
        %Result{url: url, status: nil, depth: depth, error: reason, fetched_at: DateTime.utc_now()}
    end
  end

  defp extract_links(html, base_url, config) do
    base_uri = URI.parse(base_url)

    ~r/href="([^"#]+)"/i
    |> Regex.scan(html)
    |> Enum.map(fn [_, href] -> resolve_url(href, base_uri) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn url ->
      not config.same_host_only or URI.parse(url).host == config.start_host
    end)
    |> Enum.uniq()
  end

  defp resolve_url(href, base) do
    case URI.parse(href) do
      %URI{scheme: s} when s in ["http", "https"] -> href
      %URI{scheme: nil, path: path} when is_binary(path) ->
        URI.to_string(%{base | path: path, query: nil, fragment: nil})
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
```
