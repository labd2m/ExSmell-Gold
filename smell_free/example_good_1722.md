```elixir
defmodule Content.SlugGenerator do
  @moduledoc """
  Generates unique, URL-safe slugs for content entities.

  Slugs are derived from a source string (typically a title), normalized
  to lowercase ASCII, and suffixed with an incrementing counter when
  a conflict is detected in the backing store.
  """

  alias Content.SlugStore

  @type source :: String.t()
  @type slug :: String.t()
  @type entity_type :: atom()

  @max_attempts 10

  @doc """
  Generates a unique slug for the given source string and entity type.

  Returns `{:ok, slug}` when a unique slug is found within the allowed
  attempt limit, or `{:error, :exhausted}` otherwise.
  """
  @spec generate(source(), entity_type()) :: {:ok, slug()} | {:error, :exhausted}
  def generate(source, entity_type) when is_binary(source) and is_atom(entity_type) do
    base = normalize(source)
    find_unique(base, entity_type, 0)
  end

  @doc """
  Normalizes an arbitrary string into a URL-safe slug base.

  Converts to lowercase, replaces non-alphanumeric characters with
  hyphens, collapses consecutive hyphens, and trims leading/trailing
  hyphens.
  """
  @spec normalize(source()) :: slug()
  def normalize(source) when is_binary(source) do
    source
    |> String.downcase()
    |> transliterate_accents()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.replace(~r/-{2,}/, "-")
    |> String.trim("-")
    |> truncate(80)
  end

  @spec find_unique(slug(), entity_type(), non_neg_integer()) ::
          {:ok, slug()} | {:error, :exhausted}
  defp find_unique(_base, _entity_type, attempt) when attempt >= @max_attempts do
    {:error, :exhausted}
  end

  defp find_unique(base, entity_type, 0) do
    candidate = base

    if SlugStore.taken?(entity_type, candidate) do
      find_unique(base, entity_type, 1)
    else
      {:ok, candidate}
    end
  end

  defp find_unique(base, entity_type, attempt) do
    candidate = "#{base}-#{attempt}"

    if SlugStore.taken?(entity_type, candidate) do
      find_unique(base, entity_type, attempt + 1)
    else
      {:ok, candidate}
    end
  end

  @spec transliterate_accents(String.t()) :: String.t()
  defp transliterate_accents(str) do
    str
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
  end

  @spec truncate(String.t(), pos_integer()) :: String.t()
  defp truncate(str, max_length) when byte_size(str) <= max_length, do: str

  defp truncate(str, max_length) do
    str
    |> binary_part(0, max_length)
    |> String.trim_trailing("-")
  end
end

defmodule Content.SlugStore do
  @moduledoc """
  Ecto-backed store for querying slug uniqueness across entity types.
  """

  import Ecto.Query, warn: false

  alias Content.Repo
  alias Content.Slug

  @doc "Returns `true` if the slug is already registered for the given entity type."
  @spec taken?(atom(), String.t()) :: boolean()
  def taken?(entity_type, slug) when is_atom(entity_type) and is_binary(slug) do
    Repo.exists?(from(s in Slug, where: s.entity_type == ^entity_type and s.value == ^slug))
  end

  @doc "Registers a slug for a given entity type and entity ID."
  @spec register(atom(), String.t(), String.t()) ::
          {:ok, Slug.t()} | {:error, :already_taken | Ecto.Changeset.t()}
  def register(entity_type, slug, entity_id)
      when is_atom(entity_type) and is_binary(slug) and is_binary(entity_id) do
    if taken?(entity_type, slug) do
      {:error, :already_taken}
    else
      attrs = %{entity_type: entity_type, value: slug, entity_id: entity_id}
      Repo.insert(Slug.changeset(%Slug{}, attrs))
    end
  end
end
```
