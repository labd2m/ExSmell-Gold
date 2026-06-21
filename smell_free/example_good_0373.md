```elixir
defmodule MyAppWeb.Graphql.Middleware.RequireAuthentication do
  @moduledoc """
  Absinthe middleware that enforces the presence of an authenticated actor
  on the resolution context. When an actor is absent the field resolution is
  halted immediately and a structured error is returned to the client.
  Downstream resolvers can assume `context.current_user` is always populated
  when this middleware is placed ahead of them in the pipeline.
  """

  @behaviour Absinthe.Middleware

  alias Absinthe.Resolution

  @impl Absinthe.Middleware
  def call(%Resolution{context: %{current_user: user}} = resolution, _opts)
      when not is_nil(user) do
    resolution
  end

  def call(%Resolution{} = resolution, _opts) do
    Resolution.put_result(resolution, {:error, unauthorized_error()})
  end

  defp unauthorized_error do
    %{
      message: "Authentication required",
      extensions: %{code: "UNAUTHENTICATED", http_status: 401}
    }
  end
end

defmodule MyAppWeb.Graphql.Middleware.RequireRole do
  @moduledoc """
  Absinthe middleware that enforces role-based access on a resolver. The
  required role is supplied as a compile-time option when the middleware is
  declared on a field. Resolution halts with a `:forbidden` error when the
  authenticated actor does not hold the required role.

  ## Usage in schema

      field :admin_report, :report do
        middleware MyAppWeb.Graphql.Middleware.RequireAuthentication
        middleware MyAppWeb.Graphql.Middleware.RequireRole, :admin
        resolve &Resolvers.Reports.admin_report/2
      end
  """

  @behaviour Absinthe.Middleware

  alias Absinthe.Resolution

  @impl Absinthe.Middleware
  def call(%Resolution{context: %{current_user: user}} = resolution, required_role)
      when is_atom(required_role) do
    if has_role?(user, required_role) do
      resolution
    else
      Resolution.put_result(resolution, {:error, forbidden_error(required_role)})
    end
  end

  def call(%Resolution{} = resolution, _role) do
    Resolution.put_result(resolution, {:error, forbidden_error(:unknown)})
  end

  defp has_role?(%{roles: roles}, required) when is_list(roles) do
    required in roles
  end

  defp has_role?(_user, _role), do: false

  defp forbidden_error(role) do
    %{
      message: "Insufficient permissions",
      extensions: %{code: "FORBIDDEN", required_role: role, http_status: 403}
    }
  end
end

defmodule MyAppWeb.Graphql.Context do
  @moduledoc """
  Builds the Absinthe resolution context from the inbound `Plug.Conn`.
  Resolves the bearer token from the `Authorization` header, validates it,
  and loads the authenticated user into the context map. Unauthenticated
  requests receive an empty context so public fields remain accessible.
  """

  @behaviour Plug

  import Plug.Conn

  alias MyApp.Auth.TokenVerifier

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    context = build_context(conn)
    Absinthe.Plug.put_options(conn, context: context)
  end

  defp build_context(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- TokenVerifier.verify(token),
         {:ok, user} <- MyApp.Accounts.get_user(claims["sub"]) do
      %{current_user: user, auth_claims: claims}
    else
      _ -> %{current_user: nil}
    end
  end
end
```
