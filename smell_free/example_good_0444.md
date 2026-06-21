```elixir
defmodule MyApp.Resource do
  @moduledoc """
  A macro that generates a conventional Ecto context module for a given
  schema. The generated functions (`list/1`, `fetch/1`, `create/1`,
  `update/2`, `delete/1`) follow a consistent interface so callers can
  rely on uniform return shapes across all resource types. Generators
  are used here specifically because the pattern is identical for every
  resource; application-specific business logic belongs in the consuming
  context module, not here.

  ## Usage

      defmodule MyApp.Accounts do
        use MyApp.Resource, schema: MyApp.Accounts.User, repo: MyApp.Repo
      end
  """

  defmacro __using__(opts) do
    schema = Keyword.fetch!(opts, :schema)
    repo = Keyword.fetch!(opts, :repo)

    quote do
      import Ecto.Query

      @schema unquote(schema)
      @repo unquote(repo)

      @doc """
      Returns all records for the schema, sorted by insertion order.
      Accepts an optional Ecto query for composing additional filters.
      """
      @spec list(Ecto.Queryable.t()) :: [struct()]
      def list(queryable \\ @schema) do
        queryable
        |> order_by([r], asc: r.inserted_at)
        |> @repo.all()
      end

      @doc """
      Fetches a single record by primary key.
      Returns `{:ok, record}` or `{:error, :not_found}`.
      """
      @spec fetch(binary()) :: {:ok, struct()} | {:error, :not_found}
      def fetch(id) when is_binary(id) do
        case @repo.get(@schema, id) do
          nil -> {:error, :not_found}
          record -> {:ok, record}
        end
      end

      @doc """
      Creates a record using the schema's `changeset/2` function.
      Returns `{:ok, record}` or `{:error, changeset}`.
      """
      @spec create(map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
      def create(attrs) when is_map(attrs) do
        @schema.__struct__()
        |> @schema.changeset(attrs)
        |> @repo.insert()
      end

      @doc """
      Updates an existing record using the schema's `changeset/2`.
      Returns `{:ok, record}` or `{:error, changeset | :not_found}`.
      """
      @spec update(binary(), map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t() | :not_found}
      def update(id, attrs) when is_binary(id) and is_map(attrs) do
        with {:ok, record} <- fetch(id) do
          record
          |> @schema.changeset(attrs)
          |> @repo.update()
        end
      end

      @doc """
      Deletes a record by primary key.
      Returns `{:ok, record}` or `{:error, :not_found | changeset}`.
      """
      @spec delete(binary()) :: {:ok, struct()} | {:error, :not_found | Ecto.Changeset.t()}
      def delete(id) when is_binary(id) do
        with {:ok, record} <- fetch(id) do
          @repo.delete(record)
        end
      end

      @doc """
      Returns the count of all records for the schema.
      Accepts an optional queryable for scoping.
      """
      @spec count(Ecto.Queryable.t()) :: non_neg_integer()
      def count(queryable \\ @schema) do
        @repo.aggregate(queryable, :count, :id)
      end

      @doc """
      Returns `true` when a record with the given `id` exists.
      """
      @spec exists?(binary()) :: boolean()
      def exists?(id) when is_binary(id) do
        @repo.exists?(from(r in @schema, where: r.id == ^id))
      end

      defoverridable list: 1, fetch: 1, create: 1, update: 2, delete: 1, count: 1, exists?: 1
    end
  end
end

defmodule MyApp.Accounts do
  @moduledoc """
  Context for managing user accounts. Generated CRUD operations are inherited
  from `MyApp.Resource`; domain-specific logic is added as additional
  public functions in this module.
  """

  use MyApp.Resource, schema: MyApp.Accounts.User, repo: MyApp.Repo

  import Ecto.Query

  @doc """
  Looks up a user by their email address.
  """
  @spec fetch_by_email(binary()) :: {:ok, MyApp.Accounts.User.t()} | {:error, :not_found}
  def fetch_by_email(email) when is_binary(email) do
    case MyApp.Repo.get_by(MyApp.Accounts.User, email: String.downcase(email)) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Returns all users whose email domain matches `domain`.
  """
  @spec list_by_domain(binary()) :: [MyApp.Accounts.User.t()]
  def list_by_domain(domain) when is_binary(domain) do
    MyApp.Accounts.User
    |> where([u], like(u.email, ^"%@#{domain}"))
    |> list()
  end
end
```
