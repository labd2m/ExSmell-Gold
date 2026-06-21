```elixir
defmodule MyApp.TenantRepo do
  @moduledoc """
  A thin wrapper around `MyApp.Repo` that transparently injects the current
  tenant's Postgres schema prefix into every query. The tenant context is
  stored in the process dictionary by the `TenantPlug` and read here so
  downstream context modules remain unaware of multi-tenancy mechanics.
  Any query that escapes tenant scoping (e.g., global admin queries) must
  explicitly call `MyApp.Repo` directly, making cross-tenant data access
  visibly intentional in code review.
  """

  alias MyApp.Repo

  require Logger

  @process_key :current_tenant_prefix

  @type prefix :: binary() | nil

  # ---------------------------------------------------------------------------
  # Tenant context management
  # ---------------------------------------------------------------------------

  @doc """
  Sets the current tenant prefix for the calling process. Called by
  `TenantPlug` at the start of each request.
  """
  @spec put_prefix(prefix()) :: :ok
  def put_prefix(prefix) when is_binary(prefix) or is_nil(prefix) do
    Process.put(@process_key, prefix)
    :ok
  end

  @doc """
  Returns the current tenant prefix, or `nil` for un-tenanted contexts.
  """
  @spec current_prefix() :: prefix()
  def current_prefix, do: Process.get(@process_key)

  # ---------------------------------------------------------------------------
  # Scoped repo functions
  # ---------------------------------------------------------------------------

  @doc """
  Inserts `struct_or_changeset` into the current tenant's schema.
  """
  def insert(struct_or_changeset, opts \\ []) do
    Repo.insert(struct_or_changeset, with_prefix(opts))
  end

  @doc """
  Updates `changeset` within the current tenant's schema.
  """
  def update(changeset, opts \\ []) do
    Repo.update(changeset, with_prefix(opts))
  end

  @doc """
  Deletes `struct_or_changeset` from the current tenant's schema.
  """
  def delete(struct_or_changeset, opts \\ []) do
    Repo.delete(struct_or_changeset, with_prefix(opts))
  end

  @doc """
  Returns all results for `queryable` scoped to the current tenant.
  """
  def all(queryable, opts \\ []) do
    Repo.all(queryable, with_prefix(opts))
  end

  @doc """
  Returns one result for `queryable` scoped to the current tenant.
  """
  def one(queryable, opts \\ []) do
    Repo.one(queryable, with_prefix(opts))
  end

  @doc """
  Fetches a record by primary key within the current tenant's schema.
  """
  def get(queryable, id, opts \\ []) do
    Repo.get(queryable, id, with_prefix(opts))
  end

  @doc """
  Fetches a record by the given clauses within the current tenant's schema.
  """
  def get_by(queryable, clauses, opts \\ []) do
    Repo.get_by(queryable, clauses, with_prefix(opts))
  end

  @doc """
  Executes an `Ecto.Multi` transaction within the current tenant's schema.
  """
  def transaction(multi_or_fun, opts \\ []) do
    Repo.transaction(multi_or_fun, with_prefix(opts))
  end

  @doc """
  Returns a stream of records for `queryable` within the current tenant's schema.
  Must be called within a transaction.
  """
  def stream(queryable, opts \\ []) do
    Repo.stream(queryable, with_prefix(opts))
  end

  @doc """
  Returns an aggregate value for `queryable` within the current tenant's schema.
  """
  def aggregate(queryable, aggregate, field, opts \\ []) do
    Repo.aggregate(queryable, aggregate, field, with_prefix(opts))
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp with_prefix(opts) do
    case current_prefix() do
      nil ->
        opts

      prefix ->
        Keyword.put_new(opts, :prefix, prefix)
    end
  end
end

defmodule MyAppWeb.TenantPlug do
  @moduledoc """
  Resolves the tenant from the request subdomain or `X-Tenant-ID` header
  and stores its schema prefix in the process dictionary via `TenantRepo`.
  Must be placed before any context call in the pipeline.
  """

  @behaviour Plug

  import Plug.Conn
  alias MyApp.TenantRepo

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    tenant_prefix =
      resolve_from_header(conn) ||
        resolve_from_subdomain(conn)

    TenantRepo.put_prefix(tenant_prefix)
    assign(conn, :tenant_prefix, tenant_prefix)
  end

  defp resolve_from_header(conn) do
    case get_req_header(conn, "x-tenant-id") do
      [tenant_id | _] when is_binary(tenant_id) -> "tenant_#{tenant_id}"
      _ -> nil
    end
  end

  defp resolve_from_subdomain(conn) do
    case conn.host |> String.split(".") do
      [subdomain | _] when subdomain not in ["www", "api", "app"] ->
        "tenant_#{subdomain}"

      _ ->
        nil
    end
  end
end
```
