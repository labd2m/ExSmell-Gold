```elixir
defmodule Multitenancy.Tenant do
  @moduledoc """
  Represents a resolved tenant context used to scope database queries
  and resource access for a given request or background job.
  """

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          slug: String.t(),
          schema: String.t(),
          plan: :starter | :growth | :enterprise
        }

  defstruct [:id, :slug, :schema, :plan]
end

defmodule Multitenancy.Resolver do
  import Ecto.Query

  alias Multitenancy.Tenant
  alias MyApp.Repo
  alias MyApp.Schemas.TenantRecord

  @moduledoc """
  Resolves tenant identity from inbound request attributes.
  Lookup results are cached briefly in a process dictionary
  scoped to the current request lifecycle.
  """

  @cache_key :resolved_tenant

  @spec resolve_by_slug(String.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
  def resolve_by_slug(slug) when is_binary(slug) do
    case Process.get({@cache_key, slug}) do
      nil -> fetch_and_cache(slug)
      tenant -> {:ok, tenant}
    end
  end

  @spec resolve_by_host(String.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
  def resolve_by_host(host) when is_binary(host) do
    slug = extract_slug_from_host(host)
    resolve_by_slug(slug)
  end

  @spec clear_cache() :: :ok
  def clear_cache do
    Process.get_keys()
    |> Enum.filter(fn
      {@cache_key, _} -> true
      _ -> false
    end)
    |> Enum.each(&Process.delete/1)
  end

  defp fetch_and_cache(slug) do
    TenantRecord
    |> where([t], t.slug == ^slug and t.active == true)
    |> Repo.one()
    |> case do
      nil ->
        {:error, :not_found}

      record ->
        tenant = to_tenant(record)
        Process.put({@cache_key, slug}, tenant)
        {:ok, tenant}
    end
  end

  defp extract_slug_from_host(host) do
    host
    |> String.split(".")
    |> List.first()
    |> String.downcase()
  end

  defp to_tenant(record) do
    %Tenant{
      id: record.id,
      slug: record.slug,
      schema: "tenant_#{record.slug}",
      plan: record.plan
    }
  end
end

defmodule Multitenancy.Plug do
  @behaviour Plug

  import Plug.Conn

  alias Multitenancy.Resolver

  @moduledoc """
  Resolves the current tenant from the request host and assigns it
  to `conn.assigns.current_tenant`. Returns 404 for unrecognized tenants.
  """

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    host = conn.host

    case Resolver.resolve_by_host(host) do
      {:ok, tenant} ->
        assign(conn, :current_tenant, tenant)

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "Tenant not found."}))
        |> halt()
    end
  end
end
```
