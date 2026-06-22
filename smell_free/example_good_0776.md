```elixir
defmodule Platform.TenantContextPlug do
  @moduledoc """
  Resolves the active tenant from the request and assigns it to
  `conn.assigns.tenant`. Also sets the Repo's tenant prefix when using
  schema-based multi-tenancy. Missing or inactive tenants receive a
  typed error response without leaking internal details. Tenant data
  is cached per-request to avoid repeated lookups within the same
  connection lifecycle.
  """

  @behaviour Plug

  import Plug.Conn

  alias Platform.TenantCache

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, opts) do
    strategy = Keyword.get(opts, :strategy, :header)

    case resolve(conn, strategy) do
      {:ok, tenant} ->
        conn
        |> assign(:tenant, tenant)
        |> assign(:tenant_id, tenant.id)
        |> put_repo_prefix(tenant)

      {:error, :missing} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, ~s({"error":"tenant_required"}))
        |> halt()

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, ~s({"error":"tenant_not_found"}))
        |> halt()

      {:error, :inactive} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(403, ~s({"error":"tenant_inactive"}))
        |> halt()
    end
  end

  defp resolve(conn, :header) do
    case get_req_header(conn, "x-tenant-id") do
      [tenant_id | _] -> lookup(tenant_id)
      [] -> {:error, :missing}
    end
  end

  defp resolve(conn, :subdomain) do
    case extract_subdomain(conn.host) do
      nil -> {:error, :missing}
      slug -> TenantCache.fetch_by_slug(slug)
    end
  end

  defp resolve(conn, :path) do
    case conn.path_info do
      [slug | _] when is_binary(slug) -> TenantCache.fetch_by_slug(slug)
      _ -> {:error, :missing}
    end
  end

  defp lookup(tenant_id) do
    case TenantCache.fetch_by_id(tenant_id) do
      {:ok, %{active: false}} -> {:error, :inactive}
      {:ok, tenant} -> {:ok, tenant}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp extract_subdomain(host) when is_binary(host) do
    parts = String.split(host, ".")
    if length(parts) >= 3, do: List.first(parts), else: nil
  end

  defp extract_subdomain(_), do: nil

  defp put_repo_prefix(conn, %{db_schema: schema}) when is_binary(schema) do
    Ecto.Repo.put_dynamic_repo(MyApp.Repo)
    Ecto.Repo.set_prefix(schema)
    conn
  end

  defp put_repo_prefix(conn, _tenant), do: conn
end
```
