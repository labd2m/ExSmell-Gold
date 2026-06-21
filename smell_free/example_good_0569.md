```elixir
defmodule Pagination.LinkHeader do
  @moduledoc """
  Builds RFC 5988 `Link` response headers for cursor and page-based
  HTTP pagination.

  The `Link` header is the standard way to communicate pagination URLs
  to API clients without embedding navigation metadata in the response
  body, keeping resource representations clean. Clients discover
  available pages by reading the `rel` attributes: `first`, `prev`,
  `next`, and `last`.
  """

  @type rel :: :first | :prev | :next | :last
  @type link_map :: %{optional(rel()) => String.t()}

  @spec build(link_map()) :: String.t()
  def build(links) when is_map(links) do
    links
    |> Enum.sort_by(fn {rel, _url} -> rel_order(rel) end)
    |> Enum.map_join(", ", fn {rel, url} -> ~s(<#{url}>; rel="#{rel}") end)
  end

  @spec for_page(String.t(), pos_integer(), pos_integer(), pos_integer()) :: String.t()
  def for_page(base_url, page, page_size, total_count)
      when is_binary(base_url) and page > 0 and page_size > 0 and total_count >= 0 do
    total_pages = ceil(total_count / page_size)

    links =
      %{}
      |> put_if(true, :first, page_url(base_url, 1, page_size))
      |> put_if(page > 1, :prev, page_url(base_url, page - 1, page_size))
      |> put_if(page < total_pages, :next, page_url(base_url, page + 1, page_size))
      |> put_if(total_pages > 1, :last, page_url(base_url, total_pages, page_size))

    build(links)
  end

  @spec for_cursor(String.t(), keyword()) :: String.t()
  def for_cursor(base_url, opts \\ []) when is_binary(base_url) do
    links =
      %{}
      |> maybe_cursor_link(base_url, :prev, Keyword.get(opts, :before_cursor))
      |> maybe_cursor_link(base_url, :next, Keyword.get(opts, :after_cursor))

    build(links)
  end

  @spec parse(String.t()) :: link_map()
  def parse(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.reduce(%{}, fn segment, acc ->
      case Regex.run(~r/<([^>]+)>;\s*rel="([^"]+)"/, String.trim(segment)) do
        [_, url, rel_str] ->
          case rel_str do
            "first" -> Map.put(acc, :first, url)
            "prev" -> Map.put(acc, :prev, url)
            "next" -> Map.put(acc, :next, url)
            "last" -> Map.put(acc, :last, url)
            _ -> acc
          end

        nil ->
          acc
      end
    end)
  end

  @spec set_header(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def set_header(%Plug.Conn{} = conn, link_value) when is_binary(link_value) and link_value != "" do
    Plug.Conn.put_resp_header(conn, "link", link_value)
  end

  def set_header(%Plug.Conn{} = conn, _empty), do: conn

  defp page_url(base_url, page, page_size) do
    uri = URI.parse(base_url)
    query = URI.decode_query(uri.query || "")
    new_query = URI.encode_query(Map.merge(query, %{"page" => page, "page_size" => page_size}))
    URI.to_string(%{uri | query: new_query})
  end

  defp maybe_cursor_link(links, _base, _rel, nil), do: links

  defp maybe_cursor_link(links, base_url, rel, cursor) do
    uri = URI.parse(base_url)
    query = URI.decode_query(uri.query || "")
    param = if rel == :next, do: "after", else: "before"
    new_query = URI.encode_query(Map.put(query, param, cursor))
    Map.put(links, rel, URI.to_string(%{uri | query: new_query}))
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp rel_order(:first), do: 0
  defp rel_order(:prev), do: 1
  defp rel_order(:next), do: 2
  defp rel_order(:last), do: 3
  defp rel_order(_), do: 4
end
```
