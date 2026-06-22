# File: `example_good_706.md`

```elixir
defmodule Content.MarkdownSanitizer do
  @moduledoc """
  Sanitizes user-submitted Markdown by restricting the rendered HTML
  to a configurable allowlist of tags and attributes.

  The sanitizer renders Markdown to HTML first (via the configured
  renderer), then strips any tags or attributes not explicitly allowed.
  This ensures user content cannot inject scripts, iframes, or
  unexpected event handlers regardless of the Markdown input.
  """

  @type tag :: String.t()
  @type attribute :: String.t()

  @type allowlist :: %{
          required(:tags) => [tag()],
          optional(:attributes) => %{tag() => [attribute()]},
          optional(:url_schemes) => [String.t()]
        }

  @default_allowlist %{
    tags: ~w(p br strong em a ul ol li blockquote code pre h1 h2 h3 h4 h5 h6 hr img),
    attributes: %{
      "a" => ["href", "title"],
      "img" => ["src", "alt", "title"],
      "*" => ["class"]
    },
    url_schemes: ["https", "http", "mailto"]
  }

  @type sanitize_result :: {:ok, String.t()} | {:error, :render_failed}

  @doc """
  Renders `markdown` to HTML and sanitizes it against `allowlist`.

  Returns `{:ok, safe_html}` or `{:error, :render_failed}` if the
  Markdown renderer raises.
  """
  @spec sanitize(String.t(), allowlist()) :: sanitize_result()
  def sanitize(markdown, allowlist \\ @default_allowlist) when is_binary(markdown) do
    case render_markdown(markdown) do
      {:ok, raw_html} ->
        safe = strip_disallowed(raw_html, allowlist)
        {:ok, safe}

      {:error, _reason} ->
        {:error, :render_failed}
    end
  end

  @doc """
  Strips all HTML tags from a string, returning plain text.

  Useful for generating excerpts or search index content from
  rendered HTML.
  """
  @spec to_plain_text(String.t()) :: String.t()
  def to_plain_text(html) when is_binary(html) do
    html
    |> String.replace(~r/<br\s*\/?>/, "\n")
    |> String.replace(~r/<\/p>/, "\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/&amp;/, "&")
    |> String.replace(~r/&lt;/, "<")
    |> String.replace(~r/&gt;/, ">")
    |> String.replace(~r/&quot;/, "\"")
    |> String.replace(~r/&#39;/, "'")
    |> String.trim()
  end

  @doc """
  Returns the default allowlist used when none is provided to `sanitize/2`.
  """
  @spec default_allowlist() :: allowlist()
  def default_allowlist, do: @default_allowlist

  defp render_markdown(markdown) do
    try do
      html = Earmark.as_html!(markdown, compact_output: true)
      {:ok, html}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp strip_disallowed(html, allowlist) do
    allowed_tags = MapSet.new(allowlist.tags)
    attr_rules = Map.get(allowlist, :attributes, %{})
    allowed_schemes = Map.get(allowlist, :url_schemes, ["https", "http"])

    html
    |> remove_disallowed_tags(allowed_tags)
    |> clean_attributes(attr_rules, allowed_schemes)
  end

  defp remove_disallowed_tags(html, allowed_tags) do
    Regex.replace(~r/<\/?([a-zA-Z][a-zA-Z0-9]*)[^>]*>/i, html, fn full_match, tag_name ->
      if MapSet.member?(allowed_tags, String.downcase(tag_name)) do
        full_match
      else
        ""
      end
    end)
  end

  defp clean_attributes(html, attr_rules, allowed_schemes) do
    Regex.replace(~r/<([a-zA-Z][a-zA-Z0-9]*)((?:\s+[^>]*)?)>/i, html, fn _full, tag, attrs_str ->
      tag_lower = String.downcase(tag)
      allowed = allowed_for_tag(attr_rules, tag_lower)
      cleaned_attrs = filter_attrs(attrs_str, allowed, tag_lower, allowed_schemes)
      "<#{tag}#{cleaned_attrs}>"
    end)
  end

  defp allowed_for_tag(rules, tag) do
    tag_specific = Map.get(rules, tag, [])
    global = Map.get(rules, "*", [])
    MapSet.new(tag_specific ++ global)
  end

  defp filter_attrs(attrs_str, allowed_attrs, tag, allowed_schemes) do
    Regex.scan(~r/\s+([a-zA-Z\-]+)(?:="([^"]*)")?/, attrs_str)
    |> Enum.flat_map(fn
      [_full, attr_name, attr_val] ->
        attr_lower = String.downcase(attr_name)
        if MapSet.member?(allowed_attrs, attr_lower) do
          if attr_lower in ["href", "src"] and not safe_url?(attr_val, allowed_schemes) do
            []
          else
            [" #{attr_lower}=\"#{attr_val}\""]
          end
        else
          []
        end

      [_full, attr_name] ->
        attr_lower = String.downcase(attr_name)
        if MapSet.member?(allowed_attrs, attr_lower), do: [" #{attr_lower}"], else: []
    end)
    |> Enum.join()
  end

  defp safe_url?(url, allowed_schemes) do
    case URI.parse(url) do
      %URI{scheme: nil} -> true
      %URI{scheme: scheme} -> String.downcase(scheme) in allowed_schemes
    end
  end
end
```
