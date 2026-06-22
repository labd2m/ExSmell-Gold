```elixir
defmodule Feeds.RSSParser do
  @moduledoc """
  Parses raw RSS 2.0 XML feeds into structured `FeedEntry` maps.

  Parsing is performed as a pure transformation; no I/O is performed
  here. Callers are responsible for fetching the raw XML and handling
  the resulting entries.
  """

  alias Feeds.FeedEntry

  @type raw_xml :: binary()
  @type parse_result :: {:ok, [FeedEntry.t()]} | {:error, :invalid_feed | :parse_error}

  @doc """
  Parses a raw RSS XML binary and returns a list of feed entries.

  Returns `{:ok, entries}` on success or `{:error, reason}` on failure.
  """
  @spec parse(raw_xml()) :: parse_result()
  def parse(xml) when is_binary(xml) do
    case Saxy.SimpleForm.parse_string(xml) do
      {:ok, document} -> extract_entries(document)
      {:error, _reason} -> {:error, :parse_error}
    end
  end

  @spec extract_entries(term()) :: parse_result()
  defp extract_entries({"rss", _attrs, children}) do
    case find_channel(children) do
      {:ok, channel} ->
        entries =
          channel
          |> find_items()
          |> Enum.flat_map(&parse_item/1)

        {:ok, entries}

      :error ->
        {:error, :invalid_feed}
    end
  end

  defp extract_entries(_), do: {:error, :invalid_feed}

  @spec find_channel(list()) :: {:ok, list()} | :error
  defp find_channel(nodes) do
    case Enum.find(nodes, fn
           {"channel", _, _} -> true
           _ -> false
         end) do
      {"channel", _attrs, children} -> {:ok, children}
      nil -> :error
    end
  end

  @spec find_items(list()) :: [term()]
  defp find_items(nodes) do
    Enum.filter(nodes, fn
      {"item", _, _} -> true
      _ -> false
    end)
  end

  @spec parse_item(term()) :: [FeedEntry.t()]
  defp parse_item({"item", _attrs, children}) do
    title = find_text(children, "title")
    link = find_text(children, "link")
    description = find_text(children, "description")
    pub_date = parse_date(find_text(children, "pubDate"))
    guid = find_text(children, "guid")

    case {title, link} do
      {title, link} when is_binary(title) and is_binary(link) ->
        [
          %FeedEntry{
            title: title,
            url: link,
            description: description,
            published_at: pub_date,
            guid: guid || link
          }
        ]

      _ ->
        []
    end
  end

  defp parse_item(_), do: []

  @spec find_text(list(), String.t()) :: String.t() | nil
  defp find_text(nodes, tag) do
    case Enum.find(nodes, fn
           {^tag, _, _} -> true
           _ -> false
         end) do
      {^tag, _, [{:characters, text}]} when is_binary(text) -> String.trim(text)
      {^tag, _, [text]} when is_binary(text) -> String.trim(text)
      _ -> nil
    end
  end

  @spec parse_date(String.t() | nil) :: DateTime.t() | nil
  defp parse_date(nil), do: nil

  defp parse_date(date_string) when is_binary(date_string) do
    case Timex.parse(date_string, "{RFC1123}") do
      {:ok, datetime} -> datetime
      {:error, _} -> nil
    end
  end
end
```
