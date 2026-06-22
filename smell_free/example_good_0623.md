```elixir
defmodule Content.MarkdownRenderer do
  @moduledoc """
  Renders Markdown content to sanitised HTML. Rendering happens in two
  phases: conversion from Markdown to raw HTML via Earmark, then
  sanitisation through a configurable allowlist to strip unsafe tags
  and attributes. The module exposes both phases independently so
  callers can apply custom sanitisation rules without re-running the
  converter.
  """

  @type render_opts :: [
          sanitise: boolean(),
          allowed_tags: [String.t()],
          allowed_attrs: [String.t()]
        ]

  @default_allowed_tags ~w(
    p br strong em a ul ol li blockquote code pre h1 h2 h3 h4 h5 h6
    table thead tbody tr th td hr img figure figcaption
  )

  @default_allowed_attrs ~w(href src alt title class id)

  @doc """
  Converts `markdown` to sanitised HTML. Pass `sanitise: false` to skip
  the sanitisation phase. Unrecognised tags in the sanitised output are
  stripped but their content is preserved.
  """
  @spec render(String.t(), render_opts()) :: {:ok, String.t()} | {:error, String.t()}
  def render(markdown, opts \ []) when is_binary(markdown) do
    case Earmark.as_html(markdown, earmark_opts()) do
      {:ok, html, _warnings} ->
        result =
          if Keyword.get(opts, :sanitise, true) do
            sanitise(html, opts)
          else
            html
          end

        {:ok, result}

      {:error, _html, messages} ->
        first_error = messages |> List.first() |> elem(2)
        {:error, first_error}
    end
  end

  @doc """
  Sanitises `html` against the allowed tag and attribute lists.
  Tags outside the allowlist are stripped; their text content is preserved.
  """
  @spec sanitise(String.t(), render_opts()) :: String.t()
  def sanitise(html, opts \ []) when is_binary(html) do
    allowed_tags = Keyword.get(opts, :allowed_tags, @default_allowed_tags) |> MapSet.new()
    allowed_attrs = Keyword.get(opts, :allowed_attrs, @default_allowed_attrs) |> MapSet.new()

    html
    |> strip_disallowed_tags(allowed_tags)
    |> strip_disallowed_attrs(allowed_attrs)
    |> strip_dangerous_protocols()
  end

  @doc "Extracts plain text from Markdown by rendering and stripping all HTML tags."
  @spec to_plain_text(String.t()) :: String.t()
  def to_plain_text(markdown) when is_binary(markdown) do
    case render(markdown, sanitise: false) do
      {:ok, html} -> html |> strip_all_tags() |> String.trim()
      {:error, _} -> String.trim(markdown)
    end
  end

  @doc "Returns the estimated reading time in minutes for `markdown` content."
  @spec reading_minutes(String.t()) :: float()
  def reading_minutes(markdown) when is_binary(markdown) do
    word_count =
      markdown
      |> String.split(~r/\s+/, trim: true)
      |> length()

    Float.round(word_count / 238, 1)
  end

  defp earmark_opts do
    %Earmark.Options{smartypants: false, breaks: false}
  end

  defp strip_disallowed_tags(html, allowed_tags) do
    Regex.replace(~r/<\/?([a-zA-Z][a-zA-Z0-9]*)[^>]*>/i, html, fn full_match, tag_name ->
      if MapSet.member?(allowed_tags, String.downcase(tag_name)) do
        full_match
      else
        ""
      end
    end)
  end

  defp strip_disallowed_attrs(html, allowed_attrs) do
    Regex.replace(~r/\s([a-zA-Z\-]+)="[^"]*"/i, html, fn full_match, attr_name ->
      if MapSet.member?(allowed_attrs, String.downcase(attr_name)) do
        full_match
      else
        ""
      end
    end)
  end

  defp strip_dangerous_protocols(html) do
    html
    |> String.replace(~r/href\s*=\s*"javascript:[^"]*"/i, ~s(href="#"))
    |> String.replace(~r/src\s*=\s*"javascript:[^"]*"/i, ~s(src="#"))
    |> String.replace(~r/href\s*=\s*"data:[^"]*"/i, ~s(href="#"))
  end

  defp strip_all_tags(html) do
    Regex.replace(~r/<[^>]+>/, html, "")
  end
end
```
