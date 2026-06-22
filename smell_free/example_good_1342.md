```elixir
defmodule Api.Dataloader.UserSource do
  @moduledoc """
  Dataloader batch source for resolving user records in GraphQL queries.

  Groups individual user ID lookups from multiple resolvers into a single
  database query per batch cycle, eliminating N+1 query patterns.
  """

  import Ecto.Query

  alias Accounts.Repo
  alias Accounts.Users.User

  @behaviour Dataloader.Source

  @type t :: %__MODULE__{
          queries: %{atom() => map()},
          results: %{atom() => map()}
        }

  defstruct queries: %{}, results: %{}

  @doc """
  Creates a new UserSource for use with Dataloader.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @impl Dataloader.Source
  def load(%__MODULE__{queries: queries} = source, batch_key, %{id: id}) do
    updated = Map.update(queries, batch_key, MapSet.new([id]), &MapSet.put(&1, id))
    {:ok, %{source | queries: updated}}
  end

  def load(source, _batch_key, _item), do: {:ok, source}

  @impl Dataloader.Source
  def fetch_one(%__MODULE__{results: results}, batch_key, %{id: id}) do
    case get_in(results, [batch_key, id]) do
      nil -> {:error, "user #{id} not found"}
      user -> {:ok, user}
    end
  end

  def fetch_one(_source, _batch_key, _item), do: {:error, "invalid item"}

  @impl Dataloader.Source
  def run(%__MODULE__{queries: queries} = source) do
    results =
      Map.new(queries, fn {batch_key, ids} ->
        users = fetch_users(MapSet.to_list(ids), batch_key)
        {batch_key, Map.new(users, &{&1.id, &1})}
      end)

    {:ok, %{source | results: results, queries: %{}}}
  end

  @impl Dataloader.Source
  def pending_batches?(%__MODULE__{queries: q}), do: map_size(q) > 0

  @impl Dataloader.Source
  def timeout, do: 15_000

  defp fetch_users(ids, :with_roles) do
    User
    |> where([u], u.id in ^ids)
    |> preload(:roles)
    |> Repo.all()
  end

  defp fetch_users(ids, :active_only) do
    User
    |> where([u], u.id in ^ids and u.status == :active)
    |> Repo.all()
  end

  defp fetch_users(ids, _default) do
    User
    |> where([u], u.id in ^ids)
    |> Repo.all()
  end
end

defmodule Api.Dataloader.PostSource do
  @moduledoc """
  Dataloader batch source for resolving Post records grouped by author ID.

  Enables efficient resolution of `author -> posts` associations without
  issuing a separate query per author in a list resolver.
  """

  import Ecto.Query

  alias Content.Repo
  alias Content.Posts.Post

  @behaviour Dataloader.Source

  defstruct queries: %{}, results: %{}

  @type t :: %__MODULE__{queries: map(), results: map()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @impl Dataloader.Source
  def load(%__MODULE__{queries: queries} = source, batch_key, %{author_id: author_id}) do
    updated = Map.update(queries, batch_key, MapSet.new([author_id]), &MapSet.put(&1, author_id))
    {:ok, %{source | queries: updated}}
  end

  def load(source, _, _), do: {:ok, source}

  @impl Dataloader.Source
  def fetch_one(%__MODULE__{results: results}, batch_key, %{author_id: author_id}) do
    posts = get_in(results, [batch_key, author_id]) || []
    {:ok, posts}
  end

  def fetch_one(_, _, _), do: {:ok, []}

  @impl Dataloader.Source
  def run(%__MODULE__{queries: queries} = source) do
    results =
      Map.new(queries, fn {batch_key, author_ids} ->
        posts = fetch_posts_for_authors(MapSet.to_list(author_ids), batch_key)

        by_author =
          Enum.group_by(posts, & &1.author_id)

        {batch_key, by_author}
      end)

    {:ok, %{source | results: results, queries: %{}}}
  end

  @impl Dataloader.Source
  def pending_batches?(%__MODULE__{queries: q}), do: map_size(q) > 0

  @impl Dataloader.Source
  def timeout, do: 15_000

  defp fetch_posts_for_authors(author_ids, :published_only) do
    Post
    |> where([p], p.author_id in ^author_ids and p.status == :published)
    |> order_by([p], desc: p.published_at)
    |> Repo.all()
  end

  defp fetch_posts_for_authors(author_ids, _default) do
    Post
    |> where([p], p.author_id in ^author_ids)
    |> order_by([p], desc: p.inserted_at)
    |> Repo.all()
  end
end
```
