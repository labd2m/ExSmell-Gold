```elixir
defmodule Content.Rendering.MarkdownPipeline do
  @moduledoc """
  A composable Markdown rendering pipeline.
  Each stage is a pure transformation step applied in sequence.
  Stages may be configured at call time via options.
  """

  @type stage :: (String.t(), keyword() -> String.t())
  @type pipeline :: [stage()]

  @default_pipeline [
    &__MODULE__.sanitize_html/2,
    &__MODULE__.expand_mentions/2,
    &__MODULE__.linkify_urls/2,
    &__MODULE__.render_markdown/2
  ]

  @doc """
  Runs `input` through the configured rendering pipeline.

  ## Options
    - `:pipeline` - list of stage functions (default: full pipeline)
    - `:mentions_base_url` - base URL prefix for `@mention` links
  """
  @spec render(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def render(input, opts \\ []) when is_binary(input) do
    pipeline = Keyword.get(opts, :pipeline, @default_pipeline)

    try do
      result = Enum.reduce(pipeline, input, fn stage, acc -> stage.(acc, opts) end)
      {:ok, result}
    rescue
      e -> {:error, "pipeline failure: #{Exception.message(e)}"}
    end
  end

  @doc """
  Strips unsafe HTML tags from the input string.
  """
  @spec sanitize_html(String.t(), keyword()) :: String.t()
  def sanitize_html(input, _opts) when is_binary(input) do
    input
    |> String.replace(~r/<script[^>]*>.*?<\/script>/si, "")
    |> String.replace(~r/<iframe[^>]*>.*?<\/iframe>/si, "")
    |> String.replace(~r/on\w+="[^"]*"/i, "")
  end

  @doc """
  Replaces `@username` mentions with profile links.
  """
  @spec expand_mentions(String.t(), keyword()) :: String.t()
  def expand_mentions(input, opts) when is_binary(input) do
    base_url = Keyword.get(opts, :mentions_base_url, "https://example.com/users")

    Regex.replace(~r/@([a-zA-Z0-9_]+)/, input, fn _full, username ->
      "[#{username}](#{base_url}/#{username})"
    end)
  end

  @doc """
  Converts plain URLs not already inside Markdown links into Markdown links.
  """
  @spec linkify_urls(String.t(), keyword()) :: String.t()
  def linkify_urls(input, _opts) when is_binary(input) do
    url_pattern = ~r/(?<!\()https?:\/\/[^\s\)\]]+/

    Regex.replace(url_pattern, input, fn url ->
      "[#{url}](#{url})"
    end)
  end

  @doc """
  Renders Markdown-formatted text to HTML using the Earmark library.
  """
  @spec render_markdown(String.t(), keyword()) :: String.t()
  def render_markdown(input, _opts) when is_binary(input) do
    case Earmark.as_html(input) do
      {:ok, html, _warnings} -> html
      {:error, html, _messages} -> html
    end
  end
end
```
