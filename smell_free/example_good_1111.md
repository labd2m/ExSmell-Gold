```elixir
defmodule Content.Slug do
  @moduledoc """
  Derives URL-safe slugs from arbitrary UTF-8 strings.
  Handles Unicode normalization, punctuation stripping, and collision avoidance
  by appending a short hex suffix when a candidate slug is already taken.
  """

  @separator "-"
  @max_length 80

  @type slug :: String.t()

  @doc """
  Converts a title string to a normalized URL slug.
  The resulting slug contains only ASCII lowercase letters, digits, and hyphens.
  """
  @spec from_title(String.t()) :: slug()
  def from_title(title) when is_binary(title) do
    title
    |> String.normalize(:nfd)
    |> String.downcase()
    |> remove_diacritics()
    |> strip_non_alphanumeric()
    |> collapse_separators()
    |> trim_separators()
    |> truncate(@max_length)
  end

  @doc """
  Returns a slug that does not exist in the given set of taken slugs.
  Appends an incrementing suffix until a unique candidate is found.
  """
  @spec ensure_unique(slug(), MapSet.t(slug())) :: slug()
  def ensure_unique(base_slug, taken_slugs) when is_binary(base_slug) do
    if MapSet.member?(taken_slugs, base_slug) do
      find_available(base_slug, taken_slugs, 2)
    else
      base_slug
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp remove_diacritics(str) do
    String.replace(str, ~r/\p{Mn}/u, "")
  end

  defp strip_non_alphanumeric(str) do
    String.replace(str, ~r/[^a-z0-9\s-]/u, "")
  end

  defp collapse_separators(str) do
    str
    |> String.replace(~r/[\s-]+/, @separator)
  end

  defp trim_separators(str) do
    String.trim(str, @separator)
  end

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max) do
    str
    |> String.slice(0, max)
    |> trim_separators()
  end

  defp find_available(base, taken, n) do
    candidate = "#{base}#{@separator}#{n}"
    if MapSet.member?(taken, candidate) do
      find_available(base, taken, n + 1)
    else
      candidate
    end
  end
end

defmodule Content.SlugBatch do
  @moduledoc """
  Generates unique slugs for a list of titles, ensuring no two entries
  within the batch collide with each other or with an existing slug set.
  """

  alias Content.Slug

  @doc """
  Returns a list of unique slugs corresponding to the input titles,
  in the same order. Existing slugs must be supplied as a `MapSet`.
  """
  @spec generate_all([String.t()], MapSet.t(String.t())) :: [String.t()]
  def generate_all(titles, existing_slugs \\ MapSet.new())
      when is_list(titles) do
    {slugs, _} =
      Enum.map_reduce(titles, existing_slugs, fn title, taken ->
        base = Slug.from_title(title)
        unique = Slug.ensure_unique(base, taken)
        {unique, MapSet.put(taken, unique)}
      end)
    slugs
  end
end
```
