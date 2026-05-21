# Annotated Example — Code Smell: Large code generation by macros

## Metadata

| Field                    | Detail                                                                                          |
|--------------------------|-------------------------------------------------------------------------------------------------|
| **Smell name**           | Large code generation by macros                                                                 |
| **Expected smell location** | `defmacro resource/2`, lines ~60–140                                                        |
| **Affected function(s)** | `resource/2`                                                                                    |
| **Explanation**          | Every call to `resource/2` expands a large `quote` block that validates the path prefix and controller module, computes derived route strings, writes a module attribute, and then generates a full set of CRUD route-handler function clauses (`index`, `show`, `create`, `update`, `delete`) — each with its own pattern matching and delegate call. In a real router with 10–20 resource declarations, all of this code is individually compiled per resource, increasing compilation time and binary size substantially compared to a minimal macro that delegates to a `__register_resource__/3` helper. |

---

```elixir
defmodule MyApp.Router.DSL do
  @moduledoc """
  Macro-based DSL for registering RESTful resource routes.

  Each `resource/2` declaration wires a URL path prefix to a controller
  module and generates named dispatch functions for the standard CRUD actions.

  ## Usage

      defmodule MyApp.Router do
        use MyApp.Router.DSL

        resource "/users",    MyApp.Controllers.UsersController
        resource "/invoices", MyApp.Controllers.InvoicesController
        resource "/products", MyApp.Controllers.ProductsController
        resource "/orders",   MyApp.Controllers.OrdersController
        resource "/shipments",MyApp.Controllers.ShipmentsController
      end
  """

  @allowed_methods [:get, :post, :put, :patch, :delete]

  defmacro __using__(_opts) do
    quote do
      import MyApp.Router.DSL, only: [resource: 2]
      Module.register_attribute(__MODULE__, :routes, accumulate: true)
      @before_compile MyApp.Router.DSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc "Returns a list of all registered route entries."
      def __routes__, do: @routes

      @doc "Dispatches a raw request map to the appropriate controller action."
      def dispatch(%{method: _method, path: _path} = _conn) do
        {:error, :no_matching_route}
      end
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because each resource/2 call expands this entire quote block
  # into the caller's module. The expansion includes: a binary validation on the path prefix,
  # a leading-slash check, an atom check on the controller, a derived-path computation, a
  # module-attribute write, and five separate dispatch/1 function clauses (one per CRUD verb),
  # each containing pattern-match logic on the %{method, path} map. In a router with
  # 15 resources, all five clauses per resource are compiled 15 separate times. The
  # validation and path derivation should be extracted to a plain function, leaving only
  # minimal delegate calls inside the quote.
  defmacro resource(path_prefix, controller) do
    quote do
      unless is_binary(unquote(path_prefix)) do
        raise ArgumentError,
              "resource/2: path_prefix must be a binary, got: #{inspect(unquote(path_prefix))}"
      end

      unless String.starts_with?(unquote(path_prefix), "/") do
        raise ArgumentError,
              "resource/2: path_prefix must start with \"/\", got: #{inspect(unquote(path_prefix))}"
      end

      unless is_atom(unquote(controller)) do
        raise ArgumentError,
              "resource/2: controller must be a module atom, got: #{inspect(unquote(controller))}"
      end

      index_path  = unquote(path_prefix)
      member_path = unquote(path_prefix) <> "/:id"

      @routes %{
        prefix:     unquote(path_prefix),
        controller: unquote(controller),
        actions:    [:index, :show, :create, :update, :delete]
      }

      def dispatch(%{method: :get, path: unquote(index_path)}) do
        unquote(controller).index(%{})
      end

      def dispatch(%{method: :post, path: unquote(index_path)} = conn) do
        unquote(controller).create(Map.get(conn, :body, %{}))
      end

      def dispatch(%{method: :get, path: unquote(member_path), params: %{"id" => id}}) do
        unquote(controller).show(id)
      end

      def dispatch(%{method: :put, path: unquote(member_path), params: %{"id" => id}} = conn) do
        unquote(controller).update(id, Map.get(conn, :body, %{}))
      end

      def dispatch(%{method: :delete, path: unquote(member_path), params: %{"id" => id}}) do
        unquote(controller).delete(id)
      end
    end
  end
  # VALIDATION: SMELL END

  @doc "Returns the HTTP methods supported by this router DSL."
  def allowed_methods, do: @allowed_methods
end
```
