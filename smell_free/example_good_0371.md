```elixir
defmodule Platform.TenantRouter do
  @moduledoc """
  Resolves the active tenant from an incoming Plug connection. Supports
  subdomain-based, path-prefix-based, and header-based tenant identification
  strategies. The resolved tenant is assigned to `conn.assigns.current_tenant`
  for downstream use. Unknown or missing tenants halt the request with a
  404 response to prevent information leakage.
  """

  @behaviour Plug

  import Plug.Conn

  alias Platform.TenantCache

  @type strategy :: :subdomain | :path_prefix | :header
  @type tenant :: %{id: String.t(), slug: String.t(), plan_id: String.t()}

  @tenant_header "x-tenant-id"

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, opts) do
    strategy = Keyword.get(opts, :strategy, :subdomain)

    case resolve_tenant(conn, strategy) do
      {:ok, tenant} ->
        assign(conn, :current_tenant, tenant)

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, ~s({"error":"tenant_not_found"}))
        |> halt()

      {:error, :missing_identifier} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, ~s({"error":"tenant_identifier_required"}))
        |> halt()
    end
  end

  defp resolve_tenant(conn, :subdomain) do
    case extract_subdomain(conn) do
      nil -> {:error, :missing_identifier}
      slug -> TenantCache.fetch_by_slug(slug)
    end
  end

  defp resolve_tenant(conn, :path_prefix) do
    case conn.path_info do
      [slug | _] when is_binary(slug) and byte_size(slug) > 0 ->
        TenantCache.fetch_by_slug(slug)
      _ ->
        {:error, :missing_identifier}
    end
  end

  defp resolve_tenant(conn, :header) do
    case get_req_header(conn, @tenant_header) do
      [tenant_id | _] -> TenantCache.fetch_by_id(tenant_id)
      [] -> {:error, :missing_identifier}
    end
  end

  defp extract_subdomain(conn) do
    host = conn.host || ""

    case String.split(host, ".") do
      [subdomain | rest] when length(rest) >= 1 and subdomain not in ["www", "app", "api"] ->
        subdomain
      _ ->
        nil
    end
  end
end

defmodule Platform.TenantCache do
  @moduledoc "In-memory tenant lookup cache backed by ETS."

  @table :tenant_cache

  @spec fetch_by_slug(String.t()) :: {:ok, map()} | {:error, :not_found}
  def fetch_by_slug(slug) when is_binary(slug) do
    case :ets.lookup(@table, {:slug, slug}) do
      [{_, tenant}] -> {:ok, tenant}
      [] -> {:error, :not_found}
    end
  end

  @spec fetch_by_id(String.t()) :: {:ok, map()} | {:error, :not_found}
  def fetch_by_id(id) when is_binary(id) do
    case :ets.lookup(@table, {:id, id}) do
      [{_, tenant}] -> {:ok, tenant}
      [] -> {:error, :not_found}
    end
  end
end
```
