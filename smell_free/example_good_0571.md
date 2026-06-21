```elixir
defmodule Rls.Policy do
  @moduledoc """
  Behaviour for row-level security policies applied to Ecto queries.

  Each policy module covers one schema and transforms a base query by
  appending `WHERE` clauses that restrict results to rows the given
  principal is permitted to read. Returning the query unchanged grants
  unrestricted access (e.g. for admin principals).
  """

  @callback scope(Ecto.Queryable.t(), principal :: map()) :: Ecto.Queryable.t()
end

defmodule Rls.PolicyRegistry do
  @moduledoc false

  @policies %{}

  @spec for_schema(module()) :: {:ok, module()} | {:error, :no_policy}
  def for_schema(schema) when is_atom(schema) do
    case Map.fetch(@policies, schema) do
      {:ok, _} = ok -> ok
      :error -> {:error, :no_policy}
    end
  end

  defmacro __using__(_opts) do
    quote do
      import Rls.PolicyRegistry, only: [register_policy: 2]
    end
  end

  defmacro register_policy(schema, policy_module) do
    quote do
      @policies Map.put(@policies, unquote(schema), unquote(policy_module))
    end
  end
end

defmodule Rls.ScopedRepo do
  @moduledoc """
  A principal-aware Repo wrapper that automatically scopes read queries
  through the registered row-level security policy for each schema.

  Callers set a principal for the current request via `with_principal/2`
  and then use `all/1`, `get/2`, and `one/1` as drop-in replacements for
  the corresponding `Ecto.Repo` functions. Write operations bypass RLS
  and must be guarded at the authorization layer.
  """

  @principal_key :__rls_principal__

  @spec with_principal(map(), (-> term())) :: term()
  def with_principal(principal, fun) when is_map(principal) and is_function(fun, 0) do
    previous = Process.get(@principal_key)
    Process.put(@principal_key, principal)

    try do
      fun.()
    after
      if previous, do: Process.put(@principal_key, previous), else: Process.delete(@principal_key)
    end
  end

  @spec all(Ecto.Queryable.t()) :: [term()]
  def all(queryable) do
    queryable |> scope() |> MyApp.Repo.all()
  end

  @spec get(Ecto.Queryable.t(), term()) :: term() | nil
  def get(queryable, id) do
    queryable |> scope() |> MyApp.Repo.get(id)
  end

  @spec one(Ecto.Queryable.t()) :: term() | nil
  def one(queryable) do
    queryable |> scope() |> MyApp.Repo.one()
  end

  @spec count(Ecto.Queryable.t()) :: non_neg_integer()
  def count(queryable) do
    queryable |> scope() |> MyApp.Repo.aggregate(:count, :id)
  end

  defp scope(queryable) do
    principal = Process.get(@principal_key)
    schema = resolve_schema(queryable)

    with %{} <- principal,
         {:ok, policy} <- Rls.PolicyRegistry.for_schema(schema) do
      policy.scope(queryable, principal)
    else
      _ -> queryable
    end
  end

  defp resolve_schema(%Ecto.Query{from: %{source: {_, schema}}}), do: schema
  defp resolve_schema(schema) when is_atom(schema), do: schema
  defp resolve_schema(_), do: nil
end

defmodule Documents.Policy do
  @moduledoc """
  Row-level security policy restricting document reads to the owning user,
  unless the principal carries the `:admin` role.
  """

  @behaviour Rls.Policy

  import Ecto.Query

  @impl Rls.Policy
  def scope(query, %{role: :admin}), do: query

  def scope(query, %{id: user_id}) do
    from d in query, where: d.owner_id == ^user_id
  end

  def scope(query, _unknown_principal), do: from(d in query, where: false)
end
```
