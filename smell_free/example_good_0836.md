```elixir
defmodule Tagging.Tags do
  @moduledoc """
  Manages a hierarchical tag taxonomy backed by a closure table. Tags can
  be organised into a tree (e.g. `Technology > Programming > Elixir`) for
  faceted navigation. Assigning a parent tag to content implicitly includes
  all ancestor tags in search and filter queries, handled at the database
  level via the closure table rather than application-level recursion.
  """

  alias Tagging.{Tag, TagClosure, TagAssignment, Repo}
  alias Ecto.Multi
  import Ecto.Query

  @doc """
  Creates a root tag when `parent_id` is nil, or a child tag otherwise.
  Inserts the required closure table entries atomically.
  """
  @spec create(map(), binary() | nil) :: {:ok, Tag.t()} | {:error, term()}
  def create(attrs, parent_id \\ nil) do
    Multi.new()
    |> Multi.insert(:tag, Tag.changeset(%Tag{}, Map.put(attrs, :parent_id, parent_id)))
    |> Multi.run(:closures, fn repo, %{tag: tag} ->
      rows = build_closure_rows(repo, tag.id, parent_id)
      {count, _} = repo.insert_all(TagClosure, rows)
      {:ok, count}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{tag: tag}} -> {:ok, tag}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Returns all tags that are ancestors of `tag_id`, ordered root-first.
  """
  @spec ancestors(binary()) :: [Tag.t()]
  def ancestors(tag_id) when is_binary(tag_id) do
    TagClosure
    |> join(:inner, [tc], t in Tag, on: tc.ancestor_id == t.id)
    |> where([tc], tc.descendant_id == ^tag_id and tc.depth > 0)
    |> order_by([tc], desc: tc.depth)
    |> select([_, t], t)
    |> Repo.all()
  end

  @doc """
  Returns all direct children of `tag_id`.
  """
  @spec children(binary()) :: [Tag.t()]
  def children(tag_id) when is_binary(tag_id) do
    Tag
    |> where([t], t.parent_id == ^tag_id)
    |> order_by([t], asc: t.name)
    |> Repo.all()
  end

  @doc """
  Returns the full subtree rooted at `tag_id` as a flat list with depth info.
  """
  @spec subtree(binary()) :: [%{tag: Tag.t(), depth: non_neg_integer()}]
  def subtree(tag_id) when is_binary(tag_id) do
    TagClosure
    |> join(:inner, [tc], t in Tag, on: tc.descendant_id == t.id)
    |> where([tc], tc.ancestor_id == ^tag_id)
    |> order_by([tc], asc: tc.depth)
    |> select([tc, t], %{tag: t, depth: tc.depth})
    |> Repo.all()
  end

  @doc """
  Assigns a list of `tag_ids` to `resource_id` of `resource_type`.
  Replaces any existing assignments atomically.
  """
  @spec assign(binary(), binary(), [binary()]) :: :ok | {:error, term()}
  def assign(resource_type, resource_id, tag_ids)
      when is_binary(resource_type) and is_binary(resource_id) and is_list(tag_ids) do
    Multi.new()
    |> Multi.delete_all(:clear, from(ta in TagAssignment,
         where: ta.resource_type == ^resource_type and ta.resource_id == ^resource_id))
    |> Multi.run(:insert, fn repo, _ ->
      now = DateTime.utc_now()
      rows = Enum.map(tag_ids, fn tag_id ->
        %{
          resource_type: resource_type,
          resource_id: resource_id,
          tag_id: tag_id,
          inserted_at: now,
          updated_at: now
        }
      end)

      {count, _} = repo.insert_all(TagAssignment, rows)
      {:ok, count}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _} -> :ok
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Returns all tag IDs assigned to a resource, including all ancestor tag IDs
  so hierarchical filtering works by matching only the assigned IDs.
  """
  @spec effective_tags(binary(), binary()) :: [binary()]
  def effective_tags(resource_type, resource_id)
      when is_binary(resource_type) and is_binary(resource_id) do
    direct_ids =
      TagAssignment
      |> where([ta], ta.resource_type == ^resource_type and ta.resource_id == ^resource_id)
      |> select([ta], ta.tag_id)
      |> Repo.all()

    ancestor_ids =
      TagClosure
      |> where([tc], tc.descendant_id in ^direct_ids and tc.depth > 0)
      |> select([tc], tc.ancestor_id)
      |> distinct(true)
      |> Repo.all()

    Enum.uniq(direct_ids ++ ancestor_ids)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_closure_rows(repo, tag_id, nil) do
    [%{ancestor_id: tag_id, descendant_id: tag_id, depth: 0,
       inserted_at: DateTime.utc_now(), updated_at: DateTime.utc_now()}]
  end

  defp build_closure_rows(repo, tag_id, parent_id) do
    parent_closures =
      TagClosure
      |> where([tc], tc.descendant_id == ^parent_id)
      |> repo.all()

    ancestor_rows =
      Enum.map(parent_closures, fn tc ->
        %{ancestor_id: tc.ancestor_id, descendant_id: tag_id, depth: tc.depth + 1,
          inserted_at: DateTime.utc_now(), updated_at: DateTime.utc_now()}
      end)

    self_row = %{ancestor_id: tag_id, descendant_id: tag_id, depth: 0,
                 inserted_at: DateTime.utc_now(), updated_at: DateTime.utc_now()}

    [self_row | ancestor_rows]
  end
end
```
