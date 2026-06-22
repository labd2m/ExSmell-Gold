```elixir
defmodule Persistence.Repository do
  @moduledoc """
  A generic repository pattern implemented as a behaviour that concrete
  context modules adopt. Provides standard CRUD, soft-delete, and
  pagination operations parameterised over a given Ecto schema.
  """

  @callback schema() :: module()
  @callback repo() :: module()
  @callback base_query() :: Ecto.Query.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour Persistence.Repository

      import Ecto.Query

      @spec get_by_id(String.t() | pos_integer()) ::
              {:ok, struct()} | {:error, :not_found}
      def get_by_id(id) do
        case repo().get(schema(), id) do
          nil -> {:error, :not_found}
          record -> {:ok, record}
        end
      end

      @spec list(keyword()) :: [struct()]
      def list(opts \\ []) do
        limit = Keyword.get(opts, :limit, 50)
        offset = Keyword.get(opts, :offset, 0)

        base_query()
        |> limit(^limit)
        |> offset(^offset)
        |> repo().all()
      end

      @spec create(map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
      def create(params) do
        schema().__struct__()
        |> schema().changeset(params)
        |> repo().insert()
      end

      @spec update(struct(), map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
      def update(record, params) do
        record
        |> schema().changeset(params)
        |> repo().update()
      end

      @spec delete(struct()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
      def delete(record) do
        repo().delete(record)
      end

      @spec soft_delete(struct()) :: {:ok, struct()} | {:error, Ecto.Changeset.t() | :not_soft_deletable}
      def soft_delete(record) do
        if function_exported?(schema(), :soft_delete_changeset, 1) do
          record
          |> schema().soft_delete_changeset()
          |> repo().update()
        else
          {:error, :not_soft_deletable}
        end
      end

      @spec count(keyword()) :: non_neg_integer()
      def count(opts \\ []) do
        query =
          case Keyword.get(opts, :where) do
            nil -> base_query()
            conditions -> where(base_query(), ^conditions)
          end

        repo().aggregate(query, :count, :id)
      end

      @spec exists?(keyword()) :: boolean()
      def exists?(conditions) do
        from(r in base_query(), where: ^conditions, limit: 1)
        |> repo().exists?()
      end

      defoverridable [get_by_id: 1, list: 1, create: 1, update: 2, delete: 1, count: 1]
    end
  end
end
```
