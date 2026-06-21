```elixir
defmodule MyApp.Content.SlugGenerator do
  @moduledoc """
  Produces URL-safe slugs from arbitrary title strings and ensures
  uniqueness within a given Ecto schema by appending an incrementing
  numeric suffix when a collision is detected. The uniqueness check
  issues at most one database query per suffix candidate using a single
  `IN` clause rather than sequential individual lookups.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo

  @max_slug_length 80
  @max_suffix_attempts 99

  @doc """
  Converts `title` into a slug and verifies it is unique within
  `schema` on field `field`. Returns `{:ok, slug}` or
  `{:error, :unable_to_generate_unique_slug}` after exhausting candidates.
  """
  @spec unique_slug(String.t(), module(), atom()) ::
          {:ok, String.t()} | {:error, :unable_to_generate_unique_slug}
  def unique_slug(title, schema, field \\ :slug)
      when is_binary(title) and is_atom(schema) and is_atom(field) do
    base = slugify(title)
    candidates = build_candidates(base)
    taken = fetch_taken(candidates, schema, field)

    case Enum.find(candidates, fn c -> c not in taken end) do
      nil -> {:error, :unable_to_generate_unique_slug}
      slug -> {:ok, slug}
    end
  end

  @doc """
  Converts a string to a lowercase, hyphenated, URL-safe slug.
  Non-ASCII characters are transliterated to their closest ASCII equivalent
  before any remaining non-alphanumeric characters are stripped.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(str) when is_binary(str) do
    str
    |> String.downcase()
    |> transliterate()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, @max_slug_length)
  end

  @spec build_candidates(String.t()) :: [String.t()]
  defp build_candidates(base) do
    base_candidate = [base]
    suffix_candidates = Enum.map(2..@max_suffix_attempts, fn n -> "#{base}-#{n}" end)
    base_candidate ++ suffix_candidates
  end

  @spec fetch_taken([String.t()], module(), atom()) :: MapSet.t()
  defp fetch_taken(candidates, schema, field) do
    taken =
      schema
      |> where([r], field(r, ^field) in ^candidates)
      |> select([r], field(r, ^field))
      |> Repo.all()

    MapSet.new(taken)
  end

  @spec transliterate(String.t()) :: String.t()
  defp transliterate(str) do
    str
    |> String.normalize(:nfd)
    |> String.replace(~r/[^\x00-\x7F]/, "")
  end
end
```
