# Annotated Example — Bad Code

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro define_route/2` inside `MyApp.Logistics.RouteDSL`
- **Affected function(s):** `define_route/2` macro
- **Short explanation:** Every call to `define_route/2` expands a large `quote` block containing argument validation, constraint checks, deduplication guards, and module-attribute writes inline. In a logistics module that may define dozens of routes, the compiler must expand and compile this entire block for each call, causing unnecessary code bloat and slower compilation.

---

```elixir
defmodule MyApp.Logistics.RouteDSL do
  @moduledoc """
  DSL for registering named logistics routes with their constraints.

  Example:

      defmodule MyApp.Logistics.DomesticRoutes do
        use MyApp.Logistics.RouteDSL

        define_route "SAO-RIO",
          origin: "SAO", destination: "RIO",
          max_weight_kg: 1000, carrier: :ground

        define_route "SAO-BSB",
          origin: "SAO", destination: "BSB",
          max_weight_kg: 500, carrier: :air
      end
  """

  defmacro __using__(_opts) do
    quote do
      import MyApp.Logistics.RouteDSL, only: [define_route: 2]
      Module.register_attribute(__MODULE__, :routes, accumulate: true)
      @before_compile MyApp.Logistics.RouteDSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def all_routes, do: @routes

      def find_route(code) do
        Enum.find(@routes, fn r -> r.code == code end)
      end
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because the entire validation and registration
  # VALIDATION: logic is inlined inside the quote block. Every call to
  # VALIDATION: define_route/2 causes the compiler to expand, compile, and
  # VALIDATION: emit all of this code — string checks, keyword validation,
  # VALIDATION: numeric range guards, carrier validation, deduplication checks —
  # VALIDATION: at the call site instead of delegating to a plain function.
  defmacro define_route(code, opts) do
    quote do
      code = unquote(code)
      opts = unquote(opts)

      unless is_binary(code) and byte_size(code) > 0 do
        raise ArgumentError,
              "define_route/2: route code must be a non-empty string, got #{inspect(code)}"
      end

      origin      = Keyword.get(opts, :origin)
      destination = Keyword.get(opts, :destination)
      max_weight  = Keyword.get(opts, :max_weight_kg)
      carrier     = Keyword.get(opts, :carrier)

      unless is_binary(origin) and byte_size(origin) == 3 do
        raise ArgumentError,
              "define_route/2: :origin must be a 3-letter IATA/city code, got #{inspect(origin)}"
      end

      unless is_binary(destination) and byte_size(destination) == 3 do
        raise ArgumentError,
              "define_route/2: :destination must be a 3-letter IATA/city code, " <>
                "got #{inspect(destination)}"
      end

      unless is_integer(max_weight) and max_weight > 0 do
        raise ArgumentError,
              "define_route/2: :max_weight_kg must be a positive integer, " <>
                "got #{inspect(max_weight)}"
      end

      valid_carriers = [:ground, :air, :sea, :rail]

      unless carrier in valid_carriers do
        raise ArgumentError,
              "define_route/2: :carrier must be one of #{inspect(valid_carriers)}, " <>
                "got #{inspect(carrier)}"
      end

      if origin == destination do
        raise ArgumentError,
              "define_route/2: :origin and :destination must differ (both are #{inspect(origin)})"
      end

      existing = Module.get_attribute(__MODULE__, :routes)

      if Enum.any?(existing, fn r -> r.code == code end) do
        raise ArgumentError,
              "define_route/2: duplicate route code #{inspect(code)} in #{inspect(__MODULE__)}"
      end

      route_struct = %{
        code:          code,
        origin:        origin,
        destination:   destination,
        max_weight_kg: max_weight,
        carrier:       carrier,
        extra:         Keyword.drop(opts, [:origin, :destination, :max_weight_kg, :carrier])
      }

      @routes route_struct
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Returns all routes registered across all route modules loaded in the
  application.
  """
  @spec all_registered_routes([module()]) :: [map()]
  def all_registered_routes(modules) do
    Enum.flat_map(modules, & &1.all_routes())
  end

  @doc """
  Finds the cheapest (lowest weight-limit) route between two city codes
  across all provided modules.
  """
  @spec cheapest_route([module()], String.t(), String.t()) :: map() | nil
  def cheapest_route(modules, origin, destination) do
    modules
    |> all_registered_routes()
    |> Enum.filter(fn r -> r.origin == origin and r.destination == destination end)
    |> Enum.min_by(& &1.max_weight_kg, fn -> nil end)
  end
end
```
