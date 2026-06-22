```elixir
defmodule Search.SavedQueryStore do
  @moduledoc """
  Persists, retrieves, and executes named saved search queries scoped
  to individual users. Queries are stored with their filter parameters
  and can be re-executed against current data at any time.
  """

  alias Search.{Repo, SavedQuery, QueryExecutor}
  import Ecto.Query

  @type user_id :: String.t()
  @type query_params :: map()

  @spec save(user_id(), String.t(), query_params()) ::
          {:ok, SavedQuery.t()} | {:error, Ecto.Changeset.t()}
  def save(user_id, name, params) when is_binary(user_id) and is_binary(name) do
    %SavedQuery{}
    |> SavedQuery.creation_changeset(%{
      user_id: user_id,
      name: name,
      params: params
    })
    |> Repo.insert()
  end

  @spec update(String.t(), user_id(), map()) ::
          {:ok, SavedQuery.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update(query_id, user_id, attrs) when is_binary(query_id) do
    with {:ok, query} <- fetch_owned(query_id, user_id) do
      query |> SavedQuery.update_changeset(attrs) |> Repo.update()
    end
  end

  @spec delete(String.t(), user_id()) :: :ok | {:error, :not_found}
  def delete(query_id, user_id) when is_binary(query_id) do
    with {:ok, query} <- fetch_owned(query_id, user_id) do
      Repo.delete(query)
      :ok
    end
  end

  @spec list(user_id()) :: [SavedQuery.t()]
  def list(user_id) when is_binary(user_id) do
    from(q in SavedQuery,
      where: q.user_id == ^user_id,
      order_by: [desc: q.inserted_at]
    )
    |> Repo.all()
  end

  @spec execute(String.t(), user_id(), keyword()) ::
          {:ok, map()} | {:error, :not_found | atom()}
  def execute(query_id, user_id, runtime_opts \\ []) when is_binary(query_id) do
    with {:ok, saved} <- fetch_owned(query_id, user_id) do
      merged_params = Map.merge(saved.params, Map.new(runtime_opts))

      result = QueryExecutor.run(merged_params)

      record_execution(saved)
      result
    end
  end

  @spec fetch_owned(String.t(), user_id()) ::
          {:ok, SavedQuery.t()} | {:error, :not_found}
  defp fetch_owned(query_id, user_id) do
    case Repo.get_by(SavedQuery, id: query_id, user_id: user_id) do
      nil -> {:error, :not_found}
      query -> {:ok, query}
    end
  end

  @spec record_execution(SavedQuery.t()) :: :ok
  defp record_execution(query) do
    query
    |> SavedQuery.execution_changeset(%{
      last_executed_at: DateTime.utc_now(),
      execution_count: query.execution_count + 1
    })
    |> Repo.update()

    :ok
  end
end
```
