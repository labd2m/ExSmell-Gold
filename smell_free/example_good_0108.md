```elixir
defmodule Content.SlugGenerator do
  @moduledoc """
  Generates unique URL slugs from arbitrary title strings. Handles Unicode
  normalisation, transliteration, and collision resolution by appending a
  numeric suffix. All functions are pure and stateless.
  """

  @type title :: String.t()
  @type slug :: String.t()
  @type slug_checker :: (slug() -> boolean())

  @max_slug_length 96
  @max_suffix_attempts 999

  @doc """
  Generates a URL-safe slug from `title`. Accepts a `taken?` predicate
  that returns `true` when a slug is already in use; a numeric suffix is
  appended until a free candidate is found.

  Returns `{:error, :too_many_collisions}` after #{@max_suffix_attempts} attempts.
  """
  @spec generate(title(), slug_checker()) :: {:ok, slug()} | {:error, :too_many_collisions}
  def generate(title, taken?) when is_binary(title) and is_function(taken?, 1) do
    base = to_base_slug(title)
    resolve_collision(base, taken?, 0)
  end

  @doc """
  Converts a title into a base slug without collision checking. Useful for
  deterministic generation in contexts where uniqueness is guaranteed by a
  different mechanism.
  """
  @spec to_base_slug(title()) :: slug()
  def to_base_slug(title) when is_binary(title) do
    title
    |> String.normalize(:nfc)
    |> transliterate_unicode()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s-]+/, "-")
    |> String.trim("-")
    |> truncate_to(@max_slug_length)
  end

  defp resolve_collision(_base, _taken?, attempt) when attempt > @max_suffix_attempts do
    {:error, :too_many_collisions}
  end

  defp resolve_collision(base, taken?, 0) do
    if taken?.(base), do: resolve_collision(base, taken?, 1), else: {:ok, base}
  end

  defp resolve_collision(base, taken?, attempt) do
    candidate = "#{base}-#{attempt}"
    if taken?.(candidate), do: resolve_collision(base, taken?, attempt + 1), else: {:ok, candidate}
  end

  defp transliterate_unicode(str) do
    str
    |> String.graphemes()
    |> Enum.map(&transliterate_grapheme/1)
    |> Enum.join()
  end

  defp transliterate_grapheme(g) when byte_size(g) == 1, do: g

  defp transliterate_grapheme(g) do
    case :unicode.characters_to_nfd_binary(g) do
      nfd when is_binary(nfd) ->
        nfd
        |> String.graphemes()
        |> Enum.filter(&(byte_size(&1) == 1 and &1 =~ ~r/[a-zA-Z0-9]/))
        |> Enum.join()

      _ ->
        ""
    end
  end

  defp truncate_to(str, max) when byte_size(str) <= max, do: str

  defp truncate_to(str, max) do
    str
    |> String.slice(0, max)
    |> String.trim_trailing("-")
  end
end
```
