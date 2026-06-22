```elixir
defmodule Feeds.Aggregator.SourceFetcher do
  @moduledoc """
  Fetches and normalises content from multiple external RSS/Atom feed sources.

  Each source is fetched concurrently with bounded parallelism, and results
  are normalised into a unified feed entry format for downstream processing.
  """

  alias Feeds.Aggregator.{FeedSource, FeedEntry, FeedParser, HttpClient}

  @max_concurrency 10
  @fetch_timeout_ms 15_000

  @type fetch_result ::
          {:ok, FeedSource.t(), [FeedEntry.t()]}
          | {:error, FeedSource.t(), :fetch_failed | :parse_failed | :timeout}

  @doc """
  Fetches entries from all provided feed sources concurrently.

  Returns a list of tagged results, each indicating success or the failure reason
  for the corresponding source.
  """
  @spec fetch_all([FeedSource.t()]) :: [fetch_result()]
  def fetch_all(sources) when is_list(sources) do
    sources
    |> Task.async_stream(&fetch_source/1,
      max_concurrency: @max_concurrency,
      timeout: @fetch_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.zip(sources)
    |> Enum.map(&resolve_stream_result/1)
  end

  @doc """
  Fetches a single feed source, returning normalised entries on success.
  """
  @spec fetch_source(FeedSource.t()) :: fetch_result()
  def fetch_source(%FeedSource{} = source) do
    with {:ok, body} <- HttpClient.get(source.url),
         {:ok, raw_entries} <- FeedParser.parse(body, source.format),
         entries <- Enum.map(raw_entries, &normalise_entry(&1, source)) do
      {:ok, source, entries}
    else
      {:error, :http_error} -> {:error, source, :fetch_failed}
      {:error, :parse_error} -> {:error, source, :parse_failed}
    end
  end

  @doc """
  Partitions a list of fetch results into successes and failures.
  """
  @spec partition_results([fetch_result()]) ::
          %{entries: [FeedEntry.t()], failed_sources: [FeedSource.t()]}
  def partition_results(results) do
    Enum.reduce(results, %{entries: [], failed_sources: []}, &collect_result/2)
  end

  defp collect_result({:ok, _source, entries}, acc) do
    %{acc | entries: acc.entries ++ entries}
  end

  defp collect_result({:error, source, _reason}, acc) do
    %{acc | failed_sources: [source | acc.failed_sources]}
  end

  defp resolve_stream_result({{:ok, result}, _source}), do: result

  defp resolve_stream_result({{:exit, :timeout}, source}) do
    {:error, source, :timeout}
  end

  defp resolve_stream_result({{:exit, _reason}, source}) do
    {:error, source, :fetch_failed}
  end

  defp normalise_entry(raw, %FeedSource{id: source_id, default_language: lang}) do
    %FeedEntry{
      source_id: source_id,
      external_id: raw.guid,
      title: sanitise_text(raw.title),
      summary: sanitise_text(raw.description),
      url: raw.link,
      published_at: parse_date(raw.pub_date),
      language: Map.get(raw, :language, lang),
      tags: extract_tags(raw)
    }
  end

  defp sanitise_text(nil), do: ""
  defp sanitise_text(text) when is_binary(text), do: String.trim(HtmlSanitizer.strip(text))

  defp parse_date(nil), do: DateTime.utc_now()

  defp parse_date(date_string) do
    case Timex.parse(date_string, "{RFC1123}") do
      {:ok, dt} -> Timex.to_datetime(dt, "UTC")
      {:error, _} -> DateTime.utc_now()
    end
  end

  defp extract_tags(%{categories: categories}) when is_list(categories) do
    categories |> Enum.map(&String.downcase/1) |> Enum.uniq()
  end

  defp extract_tags(_), do: []
end
```
