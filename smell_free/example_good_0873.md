```elixir
defmodule MyApp.Platform.TenantContextPlug do
  @moduledoc """
  A Plug that resolves the current tenant from the request and populates
  `conn.assigns.current_tenant`. Tenant resolution supports three
  strategies, tried in order: a custom `X-Tenant-ID` header (for API
  clients), a subdomain extracted from the `Host` header, and a path
  prefix. When no tenant can be resolved the connection is halted with
  a structured 400 response.
  """

  @behaviour Plug

  import Plug.Conn

  alias MyApp.Repo
  alias MyApp.Platform.Tenant

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> resolve_tenant()
    |> apply_tenant(conn)
  end

  @spec resolve_tenant(Plug.Conn.t()) :: {:ok, Tenant.t()} | {:error, :tenant_not_found}
  defp resolve_tenant(conn) do
    conn
    |> try_header_strategy()
    |> fallback_to_subdomain(conn)
    |> fallback_to_path(conn)
  end

  @spec try_header_strategy(Plug.Conn.t()) :: {:ok, Tenant.t()} | :miss
  defp try_header_strategy(conn) do
    case get_req_header(conn, "x-tenant-id") do
      [tenant_id | _] -> fetch_tenant_by_id(tenant_id)
      [] -> :miss
    end
  end

  @spec fallback_to_subdomain(:miss | {:ok, Tenant.t()}, Plug.Conn.t()) ::
          {:ok, Tenant.t()} | :miss
  defp fallback_to_subdomain({:ok, _} = result, _conn), do: result

  defp fallback_to_subdomain(:miss, conn) do
    case extract_subdomain(conn) do
      nil -> :miss
      slug -> fetch_tenant_by_slug(slug)
    end
  end

  @spec fallback_to_path(:miss | {:ok, Tenant.t()}, Plug.Conn.t()) ::
          {:ok, Tenant.t()} | {:error, :tenant_not_found}
  defp fallback_to_path({:ok, _} = result, _conn), do: result

  defp fallback_to_path(:miss, conn) do
    case conn.path_info do
      [slug | _] -> fetch_tenant_by_slug(slug)
      [] -> {:error, :tenant_not_found}
    end
  end

  @spec apply_tenant({:ok, Tenant.t()} | {:error, :tenant_not_found}, Plug.Conn.t()) ::
          Plug.Conn.t()
  defp apply_tenant({:ok, tenant}, conn) do
    conn
    |> assign(:current_tenant, tenant)
    |> put_private(:tenant_id, tenant.id)
  end

  defp apply_tenant({:error, :tenant_not_found}, conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{error: %{code: "tenant_required",
                                               message: "Could not determine tenant from request"}}))
    |> halt()
  end

  @spec extract_subdomain(Plug.Conn.t()) :: String.t() | nil
  defp extract_subdomain(conn) do
    host = conn.host || ""

    case String.split(host, ".") do
      [subdomain | _rest] when subdomain not in ["www", "api", ""] -> subdomain
      _ -> nil
    end
  end

  @spec fetch_tenant_by_id(String.t()) :: {:ok, Tenant.t()} | :miss
  defp fetch_tenant_by_id(id) do
    case Repo.get(Tenant, id) do
      %Tenant{active: true} = t -> {:ok, t}
      _ -> :miss
    end
  end

  @spec fetch_tenant_by_slug(String.t()) :: {:ok, Tenant.t()} | :miss
  defp fetch_tenant_by_slug(slug) do
    case Repo.get_by(Tenant, slug: slug, active: true) do
      nil -> :miss
      tenant -> {:ok, tenant}
    end
  end
end
```
