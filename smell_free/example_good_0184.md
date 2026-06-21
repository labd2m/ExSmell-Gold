```elixir
defmodule AppWeb.Plugs.BuildGraphqlContext do
  @moduledoc """
  A Plug that constructs the Absinthe context map for GraphQL requests.

  The context carries the authenticated account, a dataloader instance
  scoped to that account, and request metadata. It is injected into every
  resolver via `Absinthe.Plug` options.
  """

  import Plug.Conn

  alias App.Accounts
  alias App.Repo
  alias AppWeb.Loaders

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    context = build_context(conn)
    Absinthe.Plug.put_options(conn, context: context)
  end

  defp build_context(conn) do
    account = conn.assigns[:current_account]

    %{
      account: account,
      loader: build_loader(account),
      request_id: get_request_id(conn),
      remote_ip: format_ip(conn.remote_ip)
    }
  end

  defp build_loader(nil) do
    Dataloader.new()
    |> Dataloader.add_source(Repo, Dataloader.Ecto.new(Repo))
  end

  defp build_loader(account) do
    Dataloader.new()
    |> Dataloader.add_source(Repo, Dataloader.Ecto.new(Repo))
    |> Dataloader.add_source(Accounts, Loaders.Accounts.data(account))
  end

  defp get_request_id(conn) do
    case get_resp_header(conn, "x-request-id") do
      [id | _] -> id
      [] -> generate_request_id()
    end
  end

  defp generate_request_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: Enum.map_join([a, b, c, d, e, f, g, h], ":", &Integer.to_string(&1, 16))
  defp format_ip(_), do: "unknown"
end

defmodule AppWeb.Schema.Middleware.RequireAuthentication do
  @moduledoc """
  An Absinthe middleware that halts resolution with an auth error if no
  authenticated account is present in the context.
  """

  @behaviour Absinthe.Middleware

  @impl Absinthe.Middleware
  def call(%{context: %{account: nil}} = resolution, _opts) do
    Absinthe.Resolution.put_result(resolution, {:error, %{message: "authentication required", code: "UNAUTHENTICATED"}})
  end

  def call(%{context: %{account: _account}} = resolution, _opts) do
    resolution
  end

  def call(resolution, _opts) do
    Absinthe.Resolution.put_result(resolution, {:error, %{message: "authentication required", code: "UNAUTHENTICATED"}})
  end
end

defmodule AppWeb.Schema.Middleware.RequirePlan do
  @moduledoc """
  An Absinthe middleware that restricts field resolution to accounts
  on specific subscription plans.
  """

  @behaviour Absinthe.Middleware

  @impl Absinthe.Middleware
  def call(%{context: %{account: account}} = resolution, required_plans) when is_list(required_plans) do
    if account && account.plan in required_plans do
      resolution
    else
      Absinthe.Resolution.put_result(resolution, {:error, %{message: "plan upgrade required", code: "FORBIDDEN"}})
    end
  end

  def call(resolution, _opts) do
    Absinthe.Resolution.put_result(resolution, {:error, %{message: "forbidden", code: "FORBIDDEN"}})
  end
end
```
