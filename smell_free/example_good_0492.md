```elixir
defmodule Platform.SlugGenerator do
  @moduledoc """
  Generates URL-safe slugs from arbitrary strings and enforces uniqueness
  within a given Ecto schema using an incremental suffix strategy.

  The generated slug is always lowercase, uses hyphens as word separators,
  and strips characters that are not alphanumeric or hyphens. Collisions
  are resolved by appending `-2`, `-3`, and so on.
  """

  import Ecto.Query, only: [from: 2]
  alias Platform.Repo

  @type slug :: String.t()
  @type schema :: module()

  @max_slug_length 80
  @max_attempts 100

  @doc """
  Generates a unique slug for `schema` derived from `source_text`.

  Checks for existing slugs in the database and appends an incrementing
  numeric suffix on collision. Returns `{:error, :too_many_collisions}`
  after `#{@max_attempts}` failed attempts.
  """
  @spec generate_unique(schema(), String.t(), atom()) ::
          {:ok, slug()} | {:error, :too_many_collisions}
  def generate_unique(schema, source_text, field \\ :slug)
      when is_atom(schema) and is_binary(source_text) do
    base = slugify(source_text)
    find_available(schema, field, base, 1)
  end

  @doc """
  Converts an arbitrary string into a slug without uniqueness checking.
  Useful for displaying a preview before persistence.
  """
  @spec slugify(String.t()) :: slug()
  def slugify(text) when is_binary(text) do
    text
    |> String.downcase()
    |> transliterate()
    |> String.replace(~r/[^a-z0-9\s\-]/, "")
    |> String.replace(~r/[\s\-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, @max_slug_length)
    |> then(fn s -> if s == "", do: "item", else: s end)
  end

  @doc """
  Returns `true` if `slug` is already taken by another record in `schema`.
  Optionally excludes the record with `excluding_id` for update scenarios.
  """
  @spec taken?(schema(), slug(), atom(), pos_integer() | nil) :: boolean()
  def taken?(schema, slug, field \\ :slug, excluding_id \\ nil) do
    from(r in schema, where: field(r, ^field) == ^slug)
    |> exclude_self(excluding_id)
    |> Repo.exists?()
  end

  defp find_available(_schema, _field, _base, attempt) when attempt > @max_attempts do
    {:error, :too_many_collisions}
  end

  defp find_available(schema, field, base, 1) do
    candidate = base

    if Repo.exists?(from(r in schema, where: field(r, ^field) == ^candidate)) do
      find_available(schema, field, base, 2)
    else
      {:ok, candidate}
    end
  end

  defp find_available(schema, field, base, attempt) do
    candidate = "#{base}-#{attempt}"

    if Repo.exists?(from(r in schema, where: field(r, ^field) == ^candidate)) do
      find_available(schema, field, base, attempt + 1)
    else
      {:ok, candidate}
    end
  end

  defp exclude_self(query, nil), do: query

  defp exclude_self(query, id) when is_integer(id) do
    from(r in query, where: r.id != ^id)
  end

  defp transliterate(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace("ø", "o")
    |> String.replace("ł", "l")
    |> String.replace("æ", "ae")
    |> String.replace("ß", "ss")
  end
end
```
