```elixir
defmodule Comms.ThreadContext do
  @moduledoc """
  Manages threaded comment trees for any content type. Comments nest to
  arbitrary depth via a closure-table pattern for efficient subtree queries.
  Soft-deletion preserves thread structure: deleted nodes show placeholder
  text rather than breaking child visibility.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Comms.{Comment, CommentClosure}

  @type content_id :: Ecto.UUID.t()
  @type content_type :: String.t()
  @type comment_id :: Ecto.UUID.t()
  @type author_id :: String.t()

  @doc "Creates a root-level comment on a content item."
  @spec create_root(content_id(), content_type(), author_id(), String.t()) ::
          {:ok, Comment.t()} | {:error, Ecto.Changeset.t()}
  def create_root(content_id, content_type, author_id, body)
      when is_binary(body) and byte_size(body) > 0 do
    Repo.transaction(fn ->
      with {:ok, comment} <- insert_comment(content_id, content_type, author_id, body, nil),
           :ok <- insert_self_closure(comment.id) do
        comment
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Creates a reply to an existing comment."
  @spec create_reply(comment_id(), author_id(), String.t()) ::
          {:ok, Comment.t()} | {:error, :parent_not_found | Ecto.Changeset.t()}
  def create_reply(parent_id, author_id, body) when is_binary(body) and byte_size(body) > 0 do
    case Repo.get(Comment, parent_id) do
      nil ->
        {:error, :parent_not_found}

      parent ->
        Repo.transaction(fn ->
          with {:ok, comment} <- insert_comment(parent.content_id, parent.content_type, author_id, body, parent.id),
               :ok <- insert_reply_closures(comment.id, parent_id) do
            comment
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
    end
  end

  @doc "Returns the full comment tree for a content item as a nested list."
  @spec tree(content_id(), content_type()) :: [map()]
  def tree(content_id, content_type) do
    comments =
      from(c in Comment,
        where: c.content_id == ^content_id and c.content_type == ^content_type,
        order_by: [asc: c.inserted_at]
      )
      |> Repo.all()

    build_tree(comments, nil)
  end

  @doc "Soft-deletes a comment, preserving its place in the thread."
  @spec delete(comment_id()) :: {:ok, Comment.t()} | {:error, :not_found}
  def delete(comment_id) when is_binary(comment_id) do
    case Repo.get(Comment, comment_id) do
      nil -> {:error, :not_found}
      comment -> comment |> Comment.soft_delete_changeset() |> Repo.update()
    end
  end

  defp insert_comment(content_id, content_type, author_id, body, parent_id) do
    attrs = %{content_id: content_id, content_type: content_type,
              author_id: author_id, body: body, parent_id: parent_id}
    %Comment{} |> Comment.changeset(attrs) |> Repo.insert()
  end

  defp insert_self_closure(comment_id) do
    %CommentClosure{} |> CommentClosure.changeset(%{ancestor_id: comment_id, descendant_id: comment_id, depth: 0}) |> Repo.insert()
    :ok
  end

  defp insert_reply_closures(comment_id, parent_id) do
    ancestor_rows =
      from(cc in CommentClosure, where: cc.descendant_id == ^parent_id)
      |> Repo.all()

    Enum.each(ancestor_rows, fn row ->
      %CommentClosure{}
      |> CommentClosure.changeset(%{ancestor_id: row.ancestor_id, descendant_id: comment_id, depth: row.depth + 1})
      |> Repo.insert!()
    end)

    insert_self_closure(comment_id)
  end

  defp build_tree(comments, parent_id) do
    comments
    |> Enum.filter(fn c -> c.parent_id == parent_id end)
    |> Enum.map(fn c ->
      body = if c.deleted_at, do: "[deleted]", else: c.body
      Map.merge(c, %{body: body, children: build_tree(comments, c.id)})
    end)
  end
end
```
