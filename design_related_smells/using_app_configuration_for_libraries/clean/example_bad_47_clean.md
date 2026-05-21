```elixir
defmodule TextSanitizer do
  @moduledoc """
  A text sanitization and normalization library used across content
  ingestion pipelines, user profile updates, and product catalog imports.

  Configuration (config/config.exs):

      config :text_sanitizer,
        max_length: 500,
        strip_html: true,
        normalize_whitespace: true,
        allowed_html_tags: []
  """

  require Logger

  @html_tag_pattern ~r/<[^>]*>/
  @multi_whitespace ~r/\s{2,}/
  @control_char_pattern ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/

  @doc """
  Sanitizes a text string according to the globally configured policy:
  stripping HTML, normalizing whitespace, removing control characters,
  and enforcing maximum length.

  Returns `{:ok, sanitized_text}` or `{:error, reason}`.
  """
  @spec sanitize(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def sanitize(text) when is_binary(text) do
    max_length = Application.fetch_env!(:text_sanitizer, :max_length)
    strip_html = Application.fetch_env!(:text_sanitizer, :strip_html)
    normalize_ws = Application.fetch_env!(:text_sanitizer, :normalize_whitespace)

    result =
      text
      |> remove_control_characters()
      |> maybe_strip_html(strip_html)
      |> maybe_normalize_whitespace(normalize_ws)
      |> String.trim()
      |> truncate_to(max_length)

    {:ok, result}
  end

  @doc """
  Truncates a string to the configured maximum length, appending an
  ellipsis if truncation occurred.
  """
  @spec truncate(String.t()) :: String.t()
  def truncate(text) when is_binary(text) do
    max_length = Application.fetch_env!(:text_sanitizer, :max_length)
    truncate_to(text, max_length)
  end

  @doc """
  Returns true if the given text would be altered by `sanitize/1`.
  """
  @spec needs_sanitization?(String.t()) :: boolean()
  def needs_sanitization?(text) when is_binary(text) do
    case sanitize(text) do
      {:ok, cleaned} -> cleaned != text
      _ -> true
    end
  end

  @doc """
  Strips all HTML tags from a string unconditionally, regardless of config.
  """
  @spec strip_html(String.t()) :: String.t()
  def strip_html(text) when is_binary(text) do
    Regex.replace(@html_tag_pattern, text, "")
  end

  @doc """
  Removes leading, trailing, and excessive internal whitespace.
  """
  @spec clean_whitespace(String.t()) :: String.t()
  def clean_whitespace(text) when is_binary(text) do
    text
    |> String.trim()
    |> (&Regex.replace(@multi_whitespace, &1, " ")).()
  end

  @doc """
  Counts the word frequency in a sanitized text string.
  Returns a map of `%{word => count}`.
  """
  @spec word_frequency(String.t()) :: map()
  def word_frequency(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\w]+/, trim: true)
    |> Enum.reduce(%{}, fn word, acc ->
      Map.update(acc, word, 1, &(&1 + 1))
    end)
  end

  @doc """
  Returns a plain-text excerpt of the text, with HTML stripped and
  content truncated to `length` characters.
  """
  @spec excerpt(String.t(), pos_integer()) :: String.t()
  def excerpt(text, length) when is_binary(text) and is_integer(length) and length > 0 do
    text
    |> strip_html()
    |> clean_whitespace()
    |> truncate_to(length)
  end

  # --- Private helpers ---

  defp remove_control_characters(text) do
    Regex.replace(@control_char_pattern, text, "")
  end

  defp maybe_strip_html(text, true), do: Regex.replace(@html_tag_pattern, text, "")
  defp maybe_strip_html(text, false), do: text

  defp maybe_normalize_whitespace(text, true) do
    Regex.replace(@multi_whitespace, text, " ")
  end

  defp maybe_normalize_whitespace(text, false), do: text

  defp truncate_to(text, max) when byte_size(text) <= max, do: text

  defp truncate_to(text, max) do
    text
    |> String.slice(0, max - 1)
    |> Kernel.<>("…")
  end
end
```
