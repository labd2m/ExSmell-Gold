```elixir
defmodule Api.RouterDSL do
  @moduledoc """
  Compile-time DSL for declaring HTTP API endpoints.

  Each endpoint is bound to an HTTP method, a path template, a controller
  module/action, an optional middleware stack, and optional rate limiting.
  All parameters are validated at compile time.
  """

  @valid_methods [:get, :post, :put, :patch, :delete, :head, :options]

  defmacro endpoint(method, path, opts) do
    quote do
      method = unquote(method)
      path   = unquote(path)
      opts   = unquote(opts)

      unless method in unquote(@valid_methods) do
        raise ArgumentError,
              "endpoint method must be one of #{inspect(unquote(@valid_methods))}, got: #{inspect(method)}"
      end

      unless is_binary(path) and String.starts_with?(path, "/") do
        raise ArgumentError,
              "endpoint path must be a binary starting with '/', got: #{inspect(path)}"
      end

      controller = Keyword.fetch!(opts, :controller)

      unless is_atom(controller) do
        raise ArgumentError,
              "endpoint #{method} #{path} :controller must be a module atom"
      end

      action = Keyword.fetch!(opts, :action)

      unless is_atom(action) do
        raise ArgumentError,
              "endpoint #{method} #{path} :action must be an atom"
      end

      middleware = Keyword.get(opts, :middleware, [])

      unless is_list(middleware) and Enum.all?(middleware, &is_atom/1) do
        raise ArgumentError,
              "endpoint #{method} #{path} :middleware must be a list of module atoms"
      end

      scopes = Keyword.get(opts, :scopes, [])

      unless is_list(scopes) and Enum.all?(scopes, &is_binary/1) do
        raise ArgumentError,
              "endpoint #{method} #{path} :scopes must be a list of binary strings"
      end

      rate_limit = Keyword.get(opts, :rate_limit)

      if rate_limit != nil do
        unless is_map(rate_limit) do
          raise ArgumentError,
                "endpoint #{method} #{path} :rate_limit must be a map with :limit and :window_ms keys"
        end

        unless Map.has_key?(rate_limit, :limit) and is_integer(rate_limit.limit) do
          raise ArgumentError,
                "endpoint #{method} #{path} :rate_limit must include an integer :limit"
        end

        unless Map.has_key?(rate_limit, :window_ms) and is_integer(rate_limit.window_ms) do
          raise ArgumentError,
                "endpoint #{method} #{path} :rate_limit must include an integer :window_ms"
        end
      end

      versioned = Keyword.get(opts, :versioned, true)

      unless is_boolean(versioned) do
        raise ArgumentError,
              "endpoint #{method} #{path} :versioned must be a boolean"
      end

      @api_routes %{
        method:     method,
        path:       path,
        controller: controller,
        action:     action,
        middleware: middleware,
        scopes:     scopes,
        rate_limit: rate_limit,
        versioned:  versioned
      }
    end
  end

  defmacro __using__(_) do
    quote do
      import Api.RouterDSL, only: [endpoint: 3]
      Module.register_attribute(__MODULE__, :api_routes, accumulate: true)
      @before_compile Api.RouterDSL
    end
  end

  defmacro __before_compile__(env) do
    routes = Module.get_attribute(env.module, :api_routes)

    quote do
      def routes, do: unquote(Macro.escape(routes))

      def route(method, path) do
        Enum.find(routes(), fn r -> r.method == method and r.path == path end)
      end
    end
  end
end

defmodule Api.V1.Routes do
  use Api.RouterDSL

  endpoint(:get, "/users",
    controller: Api.V1.UsersController,
    action: :index,
    middleware: [Api.Middleware.Auth, Api.Middleware.Pagination],
    scopes: ["users:read"],
    rate_limit: %{limit: 60, window_ms: 60_000}
  )

  endpoint(:post, "/users",
    controller: Api.V1.UsersController,
    action: :create,
    middleware: [Api.Middleware.Auth],
    scopes: ["users:write"]
  )

  endpoint(:get, "/users/:id",
    controller: Api.V1.UsersController,
    action: :show,
    middleware: [Api.Middleware.Auth],
    scopes: ["users:read"]
  )

  endpoint(:put, "/users/:id",
    controller: Api.V1.UsersController,
    action: :update,
    middleware: [Api.Middleware.Auth],
    scopes: ["users:write"]
  )

  endpoint(:delete, "/users/:id",
    controller: Api.V1.UsersController,
    action: :delete,
    middleware: [Api.Middleware.Auth, Api.Middleware.MFA],
    scopes: ["users:admin"],
    rate_limit: %{limit: 5, window_ms: 60_000}
  )

  endpoint(:post, "/invoices",
    controller: Api.V1.InvoicesController,
    action: :create,
    middleware: [Api.Middleware.Auth, Api.Middleware.Idempotency],
    scopes: ["invoices:write"]
  )

  endpoint(:get, "/invoices/:id",
    controller: Api.V1.InvoicesController,
    action: :show,
    middleware: [Api.Middleware.Auth],
    scopes: ["invoices:read"]
  )

  endpoint(:post, "/invoices/:id/void",
    controller: Api.V1.InvoicesController,
    action: :void,
    middleware: [Api.Middleware.Auth, Api.Middleware.MFA],
    scopes: ["invoices:void"],
    rate_limit: %{limit: 10, window_ms: 60_000}
  )
end
```
