```elixir
defmodule HtmlSanitizer.Policy do
  @moduledoc """
  Declares which HTML tags and attributes are permitted after sanitization.
  """

  @type t :: %__MODULE__{
          allowed_tags: MapSet.t(),
          allowed_attributes: %{String.t() => [String.t()]},
          allowed_url_schemes: [String.t()],
          strip_comments: boolean()
        }

  defstruct [
    allowed_tags: MapSet.new(),
    allowed_attributes: %{},
    allowed_url_schemes: ["http", "https", "mailto"],
    strip_comments: true
  ]

  @spec basic() :: t()
  def basic do
    %__MODULE__{
      allowed_tags: MapSet.new(~w(p br b i em strong a ul ol li blockquote pre code)),
      allowed_attributes: %{
        "a" => ["href", "title"],
        "img" => ["src", "alt", "width", "height"],
        "pre" => ["class"],
        "code" => ["class"]
      }
    }
  end

  @spec rich() :: t()
  def rich do
    %__MODULE__{
      allowed_tags: MapSet.new(~w(
        p br b i em strong a ul ol li blockquote pre code
        h1 h2 h3 h4 h5 h6 table thead tbody tr td th
        img figure figcaption div span
      )),
      allowed_attributes: %{
        "a" => ["href", "title", "target"],
        "img" => ["src", "alt", "width", "height"],
        "td" => ["colspan", "rowspan"],
        "th" => ["colspan", "rowspan", "scope"],
        "pre" => ["class"],
        "code" => ["class"],
        "div" => ["class"],
        "span" => ["class"]
      }
    }
  end
end

defmodule HtmlSanitizer do
  @moduledoc """
  Sanitizes HTML strings by stripping disallowed tags and attributes.

  The sanitizer removes all tags not in the allowlist, strips disallowed
  attributes from allowed tags, and validates URL schemes in `href` and
  `src` attributes to block `javascript:` and `data:` injection. HTML
  comments are removed by default.
  """

  alias HtmlSanitizer.Policy

  @spec sanitize(String.t(), Policy.t()) :: String.t()
  def sanitize(html, %Policy{} = policy) when is_binary(html) do
    html
    |> strip_comments(policy.strip_comments)
    |> process_tags(policy)
    |> collapse_whitespace()
  end

  @spec strip_tags(String.t()) :: String.t()
  def strip_tags(html) when is_binary(html) do
    Regex.replace(~r/<[^>]+>/, html, "")
  end

  @spec escape(String.t()) :: String.t()
  def escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#x27;")
  end

  defp strip_comments(html, true) do
    Regex.replace(~r/<!--.*?-->/s, html, "")
  end

  defp strip_comments(html, false), do: html

  defp process_tags(html, policy) do
    Regex.replace(~r/<\/?[a-zA-Z][^>]*>/s, html, fn tag ->
      sanitize_tag(tag, policy)
    end)
  end

  defp sanitize_tag("</" <> rest, policy) do
    tag_name = rest |> String.trim_trailing(">") |> String.trim() |> String.downcase()

    if MapSet.member?(policy.allowed_tags, tag_name) do
      "</#{tag_name}>"
    else
      ""
    end
  end

  defp sanitize_tag(tag, policy) do
    case Regex.run(~r/<([a-zA-Z][a-zA-Z0-9]*)(.*)>/s, tag) do
      [_, tag_name, attrs_str] ->
        name = String.downcase(tag_name)

        if MapSet.member?(policy.allowed_tags, name) do
          allowed_attrs = Map.get(policy.allowed_attributes, name, [])
          clean_attrs = sanitize_attrs(attrs_str, allowed_attrs, policy.allowed_url_schemes)
          if clean_attrs == "", do: "<#{name}>", else: "<#{name} #{clean_attrs}>"
        else
          ""
        end

      _ ->
        ""
    end
  end

  defp sanitize_attrs(attrs_str, allowed_attr_names, allowed_schemes) do
    Regex.scan(~r/([a-zA-Z\-]+)=["']([^"']*)["']/, attrs_str)
    |> Enum.filter(fn [_, name, _value] -> String.downcase(name) in allowed_attr_names end)
    |> Enum.filter(fn [_, name, value] ->
      String.downcase(name) not in ["href", "src"] or safe_url?(value, allowed_schemes)
    end)
    |> Enum.map_join(" ", fn [_, name, value] -> ~s(#{name}="#{escape(value)}") end)
  end

  defp safe_url?(url, allowed_schemes) do
    case URI.parse(url) do
      %URI{scheme: nil} -> true
      %URI{scheme: scheme} -> scheme in allowed_schemes
    end
  end

  defp collapse_whitespace(html) do
    html
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end
```
