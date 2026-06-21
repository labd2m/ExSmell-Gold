```elixir
defmodule Content.CategoryTree do
  @moduledoc """
  Manages a recursive category hierarchy stored with the Closure Table pattern.
  The closure table records every ancestor-descendant pair with its depth,
  enabling efficient subtree queries without recursive CTEs. Moving,
  reparenting, and deleting subtrees are each handled as atomic operations
  that rebuild the relevant closure table entries.
  """

  alias Content.{Category, CategoryClosure, Repo}
  alias Ecto.Multi
  import Ecto.Query

  @type category_id :: binary()
  @type depth :: non_neg_integer()

  @doc """
  Creates a new category as a child of `parent_id`. When `parent_id` is `nil`
  the category becomes a root node. Inserts the required closure table entries
  to register all ancestor relationships atomically.
  Returns `{:ok, category}` or `{:error, reason}`.
  """
  @spec create(map(), category_id() | nil) :: {:ok, Category.t()} | {:error, term()}
  def create(attrs, parent_id \\ nil) do
    Multi.new()
    |> Multi.insert(:category, Category.changeset(%Category{}, Map.put(attrs, :parent_id, parent_id)))
    |> Multi.run(:closure, fn repo, %{category: category} ->
      insert_closures(repo, category.id, parent_id)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{category: category}} -> {:ok, category}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Returns all direct children of `category_id`, ordered by position.
  """
  @spec children(category_id()) :: [Category.t()]
  def children(category_id) when is_binary(category_id) do
    Category
    |> where([c], c.parent_id == ^category_id)
    |> order_by([c], asc: c.position, asc: c.name)
    |> Repo.all()
  end

  @doc """
  Returns the full subtree rooted at `category_id`, including the root itself.
  The result is a flat list ordered by depth then position.
  """
  @spec subtree(category_id()) :: [%{category: Category.t(), depth: depth()}]
  def subtree(category_id) when is_binary(category_id) do
    CategoryClosure
    |> join(:inner, [cc], c in Category, on: cc.descendant_id == c.id)
    |> where([cc], cc.ancestor_id == ^category_id)
    |> order_by([cc], asc: cc.depth)
    |> select([cc, c], %{category: c, depth: cc.depth})
    |> Repo.all()
  end

  @doc """
  Returns the ordered list of ancestors from root to `category_id`,
  useful for rendering breadcrumb navigation.
  """
  @spec ancestors(category_id()) :: [Category.t()]
  def ancestors(category_id) when is_binary(category_id) do
    CategoryClosure
    |> join(:inner, [cc], c in Category, on: cc.ancestor_id == c.id)
    |> where([cc], cc.descendant_id == ^category_id and cc.depth > 0)
    |> order_by([cc], desc: cc.depth)
    |> select([_, c], c)
    |> Repo.all()
  end

  @doc """
  Moves `category_id` to a new parent. Rebuilds all affected closure entries
  atomically. Returns `{:ok, category}` or `{:error, :would_create_cycle}`.
  """
  @spec move(category_id(), category_id() | nil) :: {:ok, Category.t()} | {:error, term()}
  def move(category_id, new_parent_id) when is_binary(category_id) do
    with {:ok, category} <- fetch(category_id),
         :ok <- assert_no_cycle(category_id, new_parent_id) do
      Multi.new()
      |> Multi.update(:category, Category.changeset(category, %{parent_id: new_parent_id}))
      |> Multi.run(:delete_old, fn repo, _ -> delete_subtree_closures(repo, category_id) end)
      |> Multi.run(:insert_new, fn repo, _ -> insert_closures(repo, category_id, new_parent_id) end)
      |> Repo.transaction()
      |> case do
        {:ok, %{category: updated}} -> {:ok, updated}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  @doc """
  Deletes `category_id` and all its descendants. Closure table entries are
  removed by cascade. Returns the count of deleted categories.
  """
  @spec delete_subtree(category_id()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_subtree(category_id) when is_binary(category_id) do
    descendant_ids =
      CategoryClosure
      |> where([cc], cc.ancestor_id == ^category_id)
      |> select([cc], cc.descendant_id)
      |> Repo.all()

    {count, _} = Repo.delete_all(from(c in Category, where: c.id in ^descendant_ids))
    {:ok, count}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch(category_id) do
    case Repo.get(Category, category_id) do
      nil -> {:error, :not_found}
      cat -> {:ok, cat}
    end
  end

  defp assert_no_cycle(_category_id, nil), do: :ok

  defp assert_no_cycle(category_id, new_parent_id) do
    is_descendant =
      CategoryClosure
      |> where([cc], cc.ancestor_id == ^category_id and cc.descendant_id == ^new_parent_id)
      |> Repo.exists?()

    if is_descendant, do: {:error, :would_create_cycle}, else: :ok
  end

  defp insert_closures(repo, category_id, nil) do
    entry = %CategoryClosure{ancestor_id: category_id, descendant_id: category_id, depth: 0}
    repo.insert(entry)
    {:ok, 1}
  end

  defp insert_closures(repo, category_id, parent_id) do
    ancestor_entries =
      CategoryClosure
      |> where([cc], cc.descendant_id == ^parent_id)
      |> repo.all()
      |> Enum.map(fn cc ->
        %{ancestor_id: cc.ancestor_id, descendant_id: category_id, depth: cc.depth + 1}
      end)

    self_entry = %{ancestor_id: category_id, descendant_id: category_id, depth: 0}
    all_entries = [self_entry | ancestor_entries]

    {count, _} = repo.insert_all(CategoryClosure, all_entries)
    {:ok, count}
  end

  defp delete_subtree_closures(repo, category_id) do
    {count, _} =
      repo.delete_all(
        from(cc in CategoryClosure,
          where:
            cc.descendant_id in subquery(
              from(inner in CategoryClosure,
                where: inner.ancestor_id == ^category_id,
                select: inner.descendant_id
              )
            )
        )
      )

    {:ok, count}
  end
end
```
