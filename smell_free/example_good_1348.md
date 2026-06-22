```elixir
defmodule API.Middleware.Authenticate do
  @moduledoc """
  Absinthe middleware that resolves the current actor from connection assigns
  and injects it into the resolution context. Unauthenticated requests are
  halted with a structured error before any field resolver executes.
  """

  @behaviour Absinthe.Middleware

  @impl Absinthe.Middleware
  def call(%Absinthe.Resolution{context: ctx} = resolution, _opts) do
    case Map.fetch(ctx, :current_claims) do
      {:ok, claims} ->
        resolution |> Absinthe.Resolution.put_private(:actor_claims, claims)

      :error ->
        resolution
        |> Absinthe.Resolution.put_result({:error, unauthorized_error()})
    end
  end

  defp unauthorized_error do
    %{message: "authentication required", extensions: %{code: "UNAUTHENTICATED"}}
  end
end

defmodule API.Middleware.HandleErrors do
  @moduledoc """
  Normalizes atom-tagged errors from resolver functions into structured
  Absinthe error maps with machine-readable extension codes.
  Resolver functions may return `{:error, atom()}` tuples and this
  middleware will translate them consistently for all clients.
  """

  @behaviour Absinthe.Middleware

  @error_map %{
    not_found: {"Resource not found", "NOT_FOUND"},
    forbidden: {"Access denied", "FORBIDDEN"},
    invalid_input: {"Invalid input provided", "INVALID_INPUT"},
    conflict: {"Resource already exists", "CONFLICT"},
    rate_limited: {"Too many requests", "RATE_LIMITED"},
    service_unavailable: {"Upstream service unavailable", "SERVICE_UNAVAILABLE"}
  }

  @impl Absinthe.Middleware
  def call(%Absinthe.Resolution{errors: []} = resolution, _opts), do: resolution

  def call(%Absinthe.Resolution{errors: errors} = resolution, _opts) do
    normalized = Enum.map(errors, &normalize_error/1)
    %{resolution | errors: normalized}
  end

  defp normalize_error(reason) when is_atom(reason) do
    case Map.fetch(@error_map, reason) do
      {:ok, {message, code}} ->
        %{message: message, extensions: %{code: code}}

      :error ->
        %{message: "An unexpected error occurred", extensions: %{code: "INTERNAL_ERROR"}}
    end
  end

  defp normalize_error(%{message: _} = err), do: err
  defp normalize_error(reason), do: %{message: inspect(reason), extensions: %{code: "UNKNOWN"}}
end

defmodule API.Resolvers.Helpers do
  @moduledoc """
  Shared resolver utilities for mapping context data, authorizing field access,
  and standardizing pagination arguments across all GraphQL resolvers.
  """

  @type resolution :: Absinthe.Resolution.t()
  @type resolver_result :: {:ok, term()} | {:error, atom()}

  @spec current_user_id(resolution()) :: {:ok, integer()} | {:error, :unauthenticated}
  def current_user_id(%Absinthe.Resolution{context: ctx}) do
    case get_in(ctx, [:current_claims, "sub"]) do
      nil -> {:error, :unauthenticated}
      id when is_integer(id) -> {:ok, id}
      id when is_binary(id) ->
        case Integer.parse(id) do
          {n, ""} -> {:ok, n}
          _ -> {:error, :unauthenticated}
        end
    end
  end

  @spec pagination_args(map()) :: {:ok, %{page: pos_integer(), page_size: pos_integer()}} | {:error, :invalid_input}
  def pagination_args(args) when is_map(args) do
    page = Map.get(args, :page, 1)
    page_size = Map.get(args, :page_size, 20)

    if is_integer(page) and page > 0 and is_integer(page_size) and page_size in 1..200 do
      {:ok, %{page: page, page_size: page_size}}
    else
      {:error, :invalid_input}
    end
  end

  @spec require_role(resolution(), atom()) :: :ok | {:error, :forbidden}
  def require_role(%Absinthe.Resolution{context: ctx}, required_role) when is_atom(required_role) do
    roles = get_in(ctx, [:current_claims, "roles"]) || []
    role_str = Atom.to_string(required_role)

    if role_str in roles, do: :ok, else: {:error, :forbidden}
  end
end
```
