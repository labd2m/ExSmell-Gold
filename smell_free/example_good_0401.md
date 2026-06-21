```elixir
defmodule Content.TagContext do
  @moduledoc """
  Manages the tag taxonomy: creation, aliasing, and association with
  content items. Tags are normalised to lowercase slugs at write time.
  Aliases redirect one tag slug to its canonical form, letting legacy
  tags remain searchable without polluting the primary namespace.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Content.{Tag, TagAlias, Tagging}

  @type slug :: String.t()
  @type content_id :: Ecto.UUID.t()
  @type content_type :: String.t()

  @doc """
  Finds a tag by slug or creates it if absent. Returns the canonical tag
  even when `slug` is an alias for another tag.
  """
  @spec find_or_create(slug()) :: {:ok, Tag.t()} | {:error, Ecto.Changeset.t()}
  def find_or_create(slug) when is_binary(slug) do
    normalised = normalise(slug)

    case resolve_alias(normalised) do
      {:ok, canonical} ->
        {:ok, canonical}

      :not_aliased ->
        case Repo.get_by(Tag, slug: normalised) do
          nil -> %Tag{} |> Tag.changeset(%{slug: normalised, label: slug}) |> Repo.insert()
          tag -> {:ok, tag}
        end
    end
  end

  @doc "Associates a list of tag slugs with a content item, creating tags as needed."
  @spec tag_content(content_id(), content_type(), [slug()]) ::
          {:ok, [Tag.t()]} | {:error, term()}
  def tag_content(content_id, content_type, slugs)
      when is_binary(content_id) and is_binary(content_type) and is_list(slugs) do
    Repo.transaction(fn ->
      Enum.map(slugs, fn slug ->
        with {:ok, tag} <- find_or_create(slug),
             {:ok, _} <- upsert_tagging(content_id, content_type, tag.id) do
          tag
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end)
  end

  @doc "Returns all tags associated with a content item."
  @spec tags_for(content_id(), content_type()) :: [Tag.t()]
  def tags_for(content_id, content_type)
      when is_binary(content_id) and is_binary(content_type) do
    from(t in Tag,
      join: tg in Tagging,
      on: tg.tag_id == t.id,
      where: tg.content_id == ^content_id and tg.content_type == ^content_type,
      order_by: t.slug
    )
    |> Repo.all()
  end

  @doc "Creates a slug alias that resolves to the canonical tag."
  @spec create_alias(slug(), slug()) ::
          {:ok, TagAlias.t()} | {:error, :canonical_not_found | Ecto.Changeset.t()}
  def create_alias(alias_slug, canonical_slug)
      when is_binary(alias_slug) and is_binary(canonical_slug) do
    with {:ok, canonical} <- fetch_tag(canonical_slug) do
      attrs = %{slug: normalise(alias_slug), canonical_tag_id: canonical.id}
      %TagAlias{} |> TagAlias.changeset(attrs) |> Repo.insert()
    end
  end

  @doc "Returns the most-used tags across all content, up to `limit`."
  @spec popular(pos_integer()) :: [%{tag: Tag.t(), count: non_neg_integer()}]
  def popular(limit \ 20) when is_integer(limit) and limit > 0 do
    from(t in Tag,
      join: tg in Tagging, on: tg.tag_id == t.id,
      group_by: t.id,
      order_by: [desc: count(tg.id)],
      limit: ^limit,
      select: %{tag: t, count: count(tg.id)}
    )
    |> Repo.all()
  end

  defp fetch_tag(slug) do
    case Repo.get_by(Tag, slug: normalise(slug)) do
      nil -> {:error, :canonical_not_found}
      tag -> {:ok, tag}
    end
  end

  defp resolve_alias(slug) do
    case Repo.get_by(TagAlias, slug: slug) |> Repo.preload(:canonical_tag) do
      %TagAlias{canonical_tag: canonical} -> {:ok, canonical}
      nil -> :not_aliased
    end
  end

  defp upsert_tagging(content_id, content_type, tag_id) do
    %Tagging{}
    |> Tagging.changeset(%{content_id: content_id, content_type: content_type, tag_id: tag_id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:content_id, :content_type, :tag_id])
  end

  defp normalise(slug), do: slug |> String.downcase() |> String.trim()
end
```
