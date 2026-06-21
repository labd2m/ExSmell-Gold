# File: `example_good_196.md`

```elixir
defmodule Catalog.SlugGenerator do
  @moduledoc """
  Generates URL-safe, human-readable slugs from arbitrary text and
  ensures uniqueness against a collision-checking function provided
  by the caller.

  Uniqueness resolution is decoupled from persistence: the caller
  supplies a predicate that checks whether a slug already exists,
  so this module works with any storage backend.
  """

  @max_base_length 80
  @max_suffix_attempts 999

  @type slug :: String.t()
  @type exists_fn :: (slug() -> boolean())

  @doc """
  Generates a unique slug from `text`, using `exists?/1` to detect
  collisions and appending a numeric suffix when needed.

  Returns `{:ok, slug}` or `{:error, :could_not_generate_unique_slug}`
  if all suffix attempts are exhausted.
  """
  @spec generate(String.t(), exists_fn()) ::
          {:ok, slug()} | {:error, :could_not_generate_unique_slug}
  def generate(text, exists?) when is_binary(text) and is_function(exists?, 1) do
    base = slugify(text)

    if base == "" do
      {:error, :could_not_generate_unique_slug}
    else
      find_unique(base, exists?)
    end
  end

  @doc """
  Converts arbitrary text to a slug without checking for uniqueness.

  Useful for previewing what a slug will look like before persisting.
  """
  @spec slugify(String.t()) :: slug()
  def slugify(text) when is_binary(text) do
    text
    |> String.downcase()
    |> transliterate_unicode()
    |> String.replace(~r/[^a-z0-9\s\-]/, "")
    |> String.replace(~r/[\s\-]+/, "-")
    |> String.trim("-")
    |> truncate_at_word_boundary(@max_base_length)
  end

  @doc """
  Returns `true` when `slug` is structurally valid (non-empty,
  contains only lowercase alphanumeric characters and hyphens,
  does not begin or end with a hyphen).
  """
  @spec valid?(slug()) :: boolean()
  def valid?(slug) when is_binary(slug) do
    byte_size(slug) > 0 and Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug)
  end

  def valid?(_slug), do: false

  defp find_unique(base, exists?) do
    if exists?.(base) do
      find_with_suffix(base, exists?, 2)
    else
      {:ok, base}
    end
  end

  defp find_with_suffix(_base, _exists?, suffix) when suffix > @max_suffix_attempts do
    {:error, :could_not_generate_unique_slug}
  end

  defp find_with_suffix(base, exists?, suffix) do
    candidate = "#{base}-#{suffix}"

    if exists?.(candidate) do
      find_with_suffix(base, exists?, suffix + 1)
    else
      {:ok, candidate}
    end
  end

  defp transliterate_unicode(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{M}/u, "")
    |> String.replace("ß", "ss")
    |> String.replace("æ", "ae")
    |> String.replace("ø", "oe")
    |> String.replace("å", "aa")
    |> String.replace("ð", "d")
    |> String.replace("þ", "th")
  end

  defp truncate_at_word_boundary(text, max_length) do
    if String.length(text) <= max_length do
      text
    else
      text
      |> String.slice(0, max_length)
      |> String.split("-")
      |> List.delete_at(-1)
      |> Enum.join("-")
      |> case do
        "" -> String.slice(text, 0, max_length)
        truncated -> truncated
      end
    end
  end
end
```
