```elixir
defmodule MyApp.Content.ReadingList do
  @moduledoc """
  Manages a user's personalised reading list: adding articles, removing
  them, marking them as read, and fetching a paginated list with read
  status. All queries are scoped to a single user ID so that no
  cross-user data leakage is possible regardless of the caller.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Content.{ReadingListEntry, Article}

  @default_limit 20
  @max_limit 100

  @type user_id :: String.t()
  @type article_id :: String.t()

  @doc """
  Adds `article_id` to `user_id`'s reading list. Returns `{:ok, entry}`
  or `{:error, :already_added}` when the article is already on the list.
  """
  @spec add(user_id(), article_id()) ::
          {:ok, ReadingListEntry.t()} | {:error, :already_added} | {:error, Ecto.Changeset.t()}
  def add(user_id, article_id) when is_binary(user_id) and is_binary(article_id) do
    case Repo.get_by(ReadingListEntry, user_id: user_id, article_id: article_id) do
      %ReadingListEntry{} ->
        {:error, :already_added}

      nil ->
        %ReadingListEntry{}
        |> ReadingListEntry.changeset(%{user_id: user_id, article_id: article_id})
        |> Repo.insert()
    end
  end

  @doc "Removes `article_id` from `user_id`'s reading list."
  @spec remove(user_id(), article_id()) :: :ok
  def remove(user_id, article_id) when is_binary(user_id) and is_binary(article_id) do
    ReadingListEntry
    |> where([e], e.user_id == ^user_id and e.article_id == ^article_id)
    |> Repo.delete_all()

    :ok
  end

  @doc "Marks `article_id` as read for `user_id`."
  @spec mark_read(user_id(), article_id()) :: :ok | {:error, :not_on_list}
  def mark_read(user_id, article_id) when is_binary(user_id) and is_binary(article_id) do
    case Repo.get_by(ReadingListEntry, user_id: user_id, article_id: article_id) do
      nil ->
        {:error, :not_on_list}

      entry ->
        entry
        |> ReadingListEntry.mark_read_changeset()
        |> Repo.update()

        :ok
    end
  end

  @doc """
  Returns a paginated reading list for `user_id`, newest additions first.
  Accepts `:read_only` and `:unread_only` filter options.
  """
  @spec list(user_id(), keyword()) :: %{entries: [map()], total: non_neg_integer()}
  def list(user_id, opts \\ []) when is_binary(user_id) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit)
    offset = Keyword.get(opts, :offset, 0)
    filter = Keyword.get(opts, :filter, :all)

    base =
      ReadingListEntry
      |> where([e], e.user_id == ^user_id)
      |> join(:inner, [e], a in Article, on: a.id == e.article_id)
      |> apply_read_filter(filter)

    total = base |> select([e, _a], count(e.id)) |> Repo.one() |> Kernel.||(0)

    entries =
      base
      |> select([e, a], %{
        article_id: a.id,
        title: a.title,
        slug: a.slug,
        published_at: a.published_at,
        added_at: e.inserted_at,
        read_at: e.read_at
      })
      |> order_by([e, _a], desc: e.inserted_at)
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all()

    %{entries: entries, total: total}
  end

  @spec apply_read_filter(Ecto.Query.t(), :all | :read_only | :unread_only) :: Ecto.Query.t()
  defp apply_read_filter(q, :read_only), do: where(q, [e, _a], not is_nil(e.read_at))
  defp apply_read_filter(q, :unread_only), do: where(q, [e, _a], is_nil(e.read_at))
  defp apply_read_filter(q, :all), do: q
end
```
