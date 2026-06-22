```elixir
defmodule DataAccess.ScopedRepository do
  @moduledoc """
  Data access layer that enforces row-level permission scopes on all queries.

  Every query is automatically filtered by the caller's permission scope,
  ensuring data from other tenants or restricted resources is never returned.
  Scopes are passed explicitly per call rather than stored in process state.
  """

  import Ecto.Query

  alias DataAccess.{Repo, PermissionScope}

  @doc """
  Fetches a single record by ID, returning `nil` if not visible under the scope.
  """
  @spec fetch(module(), String.t(), PermissionScope.t()) :: {:ok, struct()} | {:error, :not_found}
  def fetch(schema, id, %PermissionScope{} = scope) when is_atom(schema) and is_binary(id) do
    query =
      schema
      |> where([r], r.id == ^id)
      |> apply_scope(scope, schema)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @doc """
  Returns all records visible under the given scope, with optional ordering and pagination.
  """
  @spec list(module(), PermissionScope.t(), keyword()) :: [struct()]
  def list(schema, %PermissionScope{} = scope, opts \\ []) when is_atom(schema) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)
    order = Keyword.get(opts, :order_by, [asc: :inserted_at])

    schema
    |> apply_scope(scope, schema)
    |> order_by(^order)
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> Repo.all()
  end

  @doc """
  Counts records visible under the given scope.
  """
  @spec count(module(), PermissionScope.t()) :: non_neg_integer()
  def count(schema, %PermissionScope{} = scope) when is_atom(schema) do
    schema
    |> apply_scope(scope, schema)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Checks whether a record with the given ID exists within the scope.
  """
  @spec exists?(module(), String.t(), PermissionScope.t()) :: boolean()
  def exists?(schema, id, %PermissionScope{} = scope) when is_atom(schema) and is_binary(id) do
    schema
    |> where([r], r.id == ^id)
    |> apply_scope(scope, schema)
    |> Repo.exists?()
  end

  # --- scope application ---

  defp apply_scope(query, %PermissionScope{kind: :tenant, tenant_id: tid}, _schema) do
    where(query, [r], r.tenant_id == ^tid)
  end

  defp apply_scope(query, %PermissionScope{kind: :owner, user_id: uid}, _schema) do
    where(query, [r], r.owner_id == ^uid)
  end

  defp apply_scope(query, %PermissionScope{kind: :tenant_and_owner, tenant_id: tid, user_id: uid}, _schema) do
    where(query, [r], r.tenant_id == ^tid and r.owner_id == ^uid)
  end

  defp apply_scope(query, %PermissionScope{kind: :unrestricted}, _schema), do: query
end

defmodule DataAccess.PermissionScope do
  @moduledoc "Describes the row-level access scope applied to scoped repository queries."

  @enforce_keys [:kind]
  defstruct [:kind, :tenant_id, :user_id]

  @type scope_kind :: :tenant | :owner | :tenant_and_owner | :unrestricted

  @type t :: %__MODULE__{
          kind: scope_kind(),
          tenant_id: String.t() | nil,
          user_id: String.t() | nil
        }

  @spec for_tenant(String.t()) :: t()
  def for_tenant(tenant_id) when is_binary(tenant_id),
    do: %__MODULE__{kind: :tenant, tenant_id: tenant_id}

  @spec for_owner(String.t()) :: t()
  def for_owner(user_id) when is_binary(user_id),
    do: %__MODULE__{kind: :owner, user_id: user_id}

  @spec for_tenant_and_owner(String.t(), String.t()) :: t()
  def for_tenant_and_owner(tenant_id, user_id)
      when is_binary(tenant_id) and is_binary(user_id),
    do: %__MODULE__{kind: :tenant_and_owner, tenant_id: tenant_id, user_id: user_id}

  @spec unrestricted() :: t()
  def unrestricted, do: %__MODULE__{kind: :unrestricted}
end
```
