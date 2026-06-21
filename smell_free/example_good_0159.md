```elixir
defmodule Tenancy.Context do
  @moduledoc """
  Stores the current tenant identifier in the calling process's dictionary.

  The context is set once at request boundary (e.g. in a Plug) and read
  transparently by query scoping helpers throughout the call stack. This
  avoids threading a tenant ID through every function signature while
  keeping each process's tenant completely isolated.
  """

  @key :current_tenant_id

  @spec put(String.t()) :: :ok
  def put(tenant_id) when is_binary(tenant_id) do
    Process.put(@key, tenant_id)
    :ok
  end

  @spec fetch() :: {:ok, String.t()} | {:error, :no_tenant}
  def fetch do
    case Process.get(@key) do
      nil -> {:error, :no_tenant}
      tenant_id -> {:ok, tenant_id}
    end
  end

  @spec clear() :: :ok
  def clear do
    Process.delete(@key)
    :ok
  end
end

defmodule Tenancy.Scope do
  @moduledoc """
  Applies the current tenant scope to an Ecto query.

  All multi-tenant schemas include a `tenant_id` column. Calling
  `apply/1` reads the tenant from the process context and appends a
  `WHERE tenant_id = $n` clause, ensuring no query can accidentally
  return cross-tenant data when the context is set.
  """

  import Ecto.Query

  alias Tenancy.Context

  @spec apply(Ecto.Queryable.t()) :: {:ok, Ecto.Query.t()} | {:error, :no_tenant}
  def apply(queryable) do
    case Context.fetch() do
      {:ok, tenant_id} -> {:ok, from(r in queryable, where: r.tenant_id == ^tenant_id)}
      {:error, :no_tenant} -> {:error, :no_tenant}
    end
  end

  @spec apply!(Ecto.Queryable.t()) :: Ecto.Query.t()
  def apply!(queryable) do
    case __MODULE__.apply(queryable) do
      {:ok, query} -> query
      {:error, :no_tenant} -> raise "attempted to run a scoped query without a tenant context"
    end
  end
end

defmodule Tenancy.Plug do
  @moduledoc """
  Extracts the tenant identifier from the request and installs it in the
  process context for the duration of the connection lifecycle.
  """

  @behaviour Plug

  alias Tenancy.Context
  alias Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Conn{} = conn, _opts) do
    case resolve_tenant(conn) do
      {:ok, tenant_id} ->
        Context.put(tenant_id)
        Conn.register_before_send(conn, fn c -> Context.clear(); c end)

      {:error, :missing_tenant} ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.send_resp(400, Jason.encode!(%{error: "Tenant identifier required"}))
        |> Conn.halt()
    end
  end

  defp resolve_tenant(conn) do
    case Conn.get_req_header(conn, "x-tenant-id") do
      [tenant_id | _] when tenant_id != "" -> {:ok, tenant_id}
      _ -> {:error, :missing_tenant}
    end
  end
end

defmodule TenantAware.Repo do
  @moduledoc """
  Thin wrapper around the application Repo that automatically applies
  tenant scoping to all read queries.
  """

  alias MyApp.Repo
  alias Tenancy.Scope

  @spec all(Ecto.Queryable.t()) :: [term()]
  def all(queryable) do
    queryable |> Scope.apply!() |> Repo.all()
  end

  @spec get(Ecto.Queryable.t(), term()) :: term() | nil
  def get(queryable, id) do
    queryable |> Scope.apply!() |> Repo.get(id)
  end

  @spec one(Ecto.Queryable.t()) :: term() | nil
  def one(queryable) do
    queryable |> Scope.apply!() |> Repo.one()
  end
end
```
