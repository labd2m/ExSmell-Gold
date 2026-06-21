```elixir
defmodule MyAppWeb.Schema.Context do
  @moduledoc """
  Builds the Absinthe context map for every GraphQL request.

  The context carries: the authenticated principal (or `nil` for public
  queries), the resolved tenant identifier, and a preloaded Dataloader
  instance so resolvers can batch database calls without N+1 queries.
  Context building runs as a Plug so it benefits from the full connection
  lifecycle including request ID logging.
  """

  @behaviour Plug

  alias Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Conn{} = conn, _opts) do
    context = %{
      principal: resolve_principal(conn),
      tenant_id: resolve_tenant(conn),
      loader: build_dataloader(),
      request_id: Conn.get_resp_header(conn, "x-request-id") |> List.first()
    }

    Absinthe.Plug.put_options(conn, context: context)
  end

  defp resolve_principal(conn) do
    with ["Bearer " <> token] <- Conn.get_req_header(conn, "authorization"),
         {:ok, claims} <- Auth.Jwt.verify(token, auth_secret(), issuer: issuer()) do
      %{id: claims.sub, claims: claims.extra}
    else
      _ -> nil
    end
  end

  defp resolve_tenant(conn) do
    case Conn.get_req_header(conn, "x-tenant-id") do
      [tenant_id | _] when tenant_id != "" -> tenant_id
      _ -> nil
    end
  end

  defp build_dataloader do
    Dataloader.new()
    |> Dataloader.add_source(Accounts, Accounts.dataloader_source())
    |> Dataloader.add_source(Catalog, Catalog.dataloader_source())
    |> Dataloader.add_source(Orders, Orders.dataloader_source())
  end

  defp auth_secret, do: Application.fetch_env!(:my_app, :jwt_secret)
  defp issuer, do: Application.get_env(:my_app, :jwt_issuer, "myapp")
end

defmodule MyAppWeb.Schema.Helpers do
  @moduledoc """
  Convenience macros for resolver functions that require an authenticated
  principal or a specific role before executing.
  """

  alias Absinthe.Resolution

  @spec with_authenticated_user(Resolution.t(), (map(), Resolution.t() -> term())) :: term()
  def with_authenticated_user(%Resolution{context: %{principal: nil}} = res, _fun) do
    Resolution.put_result(res, {:error, %{message: "Authentication required", code: :unauthenticated}})
  end

  def with_authenticated_user(%Resolution{context: %{principal: principal}} = res, fun) do
    fun.(principal, res)
  end

  @spec require_role(map(), atom()) :: :ok | {:error, map()}
  def require_role(%{claims: %{"role" => role}}, required) when role == Atom.to_string(required) do
    :ok
  end

  def require_role(_principal, required) do
    {:error, %{message: "Role #{required} required", code: :forbidden}}
  end

  @spec load(Resolution.t(), module(), atom(), term()) :: term()
  def load(%Resolution{context: %{loader: loader}} = res, source, batch_key, id) do
    loader
    |> Dataloader.load(source, batch_key, id)
    |> Absinthe.Resolution.Helpers.on_load(res, fn loader, res ->
      result = Dataloader.get(loader, source, batch_key, id)
      Resolution.put_result(res, {:ok, result})
    end)
  end
end
```
