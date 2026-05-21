```elixir
defmodule SlugGenerator do
  @moduledoc """
  A URL slug generation library for producing human-readable, URL-safe
  identifiers from arbitrary text inputs. Used across CMS modules,
  product catalogs, and blog publishing pipelines.

  Configuration (config/config.exs):

      config :slug_generator,
        max_slug_length: 80,
        separator: "-",
        locale: :en,
        transliterate: true
  """

  @transliteration_table %{
    "á" => "a", "à" => "a", "ä" => "a", "â" => "a", "ã" => "a",
    "é" => "e", "è" => "e", "ë" => "e", "ê" => "e",
    "í" => "i", "ì" => "i", "ï" => "i", "î" => "i",
    "ó" => "o", "ò" => "o", "ö" => "o", "ô" => "o", "õ" => "o",
    "ú" => "u", "ù" => "u", "ü" => "u", "û" => "u",
    "ñ" => "n", "ç" => "c", "ß" => "ss",
    "æ" => "ae", "ø" => "o", "å" => "a"
  }

  @doc """
  Generates a URL-safe slug from the given text input.
  Uses globally configured separator, length limit, and transliteration settings.

  ## Examples

      iex> SlugGenerator.generate("Hello, World!")
      "hello-world"
  """
  @spec generate(String.t()) :: String.t()
  def generate(text) when is_binary(text) do
    max_length = Application.fetch_env!(:slug_generator, :max_slug_length)
    separator = Application.fetch_env!(:slug_generator, :separator)
    transliterate = Application.fetch_env!(:slug_generator, :transliterate)

    text
    |> String.downcase()
    |> maybe_transliterate(transliterate)
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/[\s_]+/, separator)
    |> String.replace(~r/-{2,}/, separator)
    |> String.trim(separator)
    |> truncate_slug(max_length, separator)
  end

  @doc """
  Generates a slug and ensures uniqueness by appending a numeric suffix if
  the slug already exists in the provided `existing_slugs` set.
  """
  @spec generate_unique(String.t(), MapSet.t()) :: String.t()
  def generate_unique(text, existing_slugs) when is_binary(text) do
    separator = Application.fetch_env!(:slug_generator, :separator)
    base = generate(text)

    if MapSet.member?(existing_slugs, base) do
      find_unique(base, existing_slugs, separator, 2)
    else
      base
    end
  end

  @doc """
  Returns true if the given string is a valid slug (i.e., it would not be
  altered by `generate/1`).
  """
  @spec valid_slug?(String.t()) :: boolean()
  def valid_slug?(slug) when is_binary(slug) do
    separator = Application.fetch_env!(:slug_generator, :separator)
    pattern = ~r/^[a-z0-9#{Regex.escape(separator)}]+$/

    Regex.match?(pattern, slug) and not String.starts_with?(slug, separator) and
      not String.ends_with?(slug, separator)
  end

  @doc """
  Converts a slug back to a human-readable title by replacing separators
  with spaces and capitalizing each word.
  """
  @spec to_title(String.t()) :: String.t()
  def to_title(slug) when is_binary(slug) do
    separator = Application.fetch_env!(:slug_generator, :separator)

    slug
    |> String.split(separator)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  @doc """
  Joins multiple slug segments with the configured separator.
  """
  @spec join(list(String.t())) :: String.t()
  def join(segments) when is_list(segments) do
    separator = Application.fetch_env!(:slug_generator, :separator)

    segments
    |> Enum.map(&generate/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(separator)
  end

  # --- Private helpers ---

  defp maybe_transliterate(text, false), do: text

  defp maybe_transliterate(text, true) do
    Enum.reduce(@transliteration_table, text, fn {from, to}, acc ->
      String.replace(acc, from, to)
    end)
  end

  defp truncate_slug(slug, max, separator) do
    if String.length(slug) <= max do
      slug
    else
      slug
      |> String.slice(0, max)
      |> String.trim_trailing(separator)
    end
  end

  defp find_unique(base, existing, separator, n) do
    candidate = "#{base}#{separator}#{n}"

    if MapSet.member?(existing, candidate) do
      find_unique(base, existing, separator, n + 1)
    else
      candidate
    end
  end
end
```
