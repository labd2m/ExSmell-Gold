```elixir
defmodule Pipeline.Middleware do
  @moduledoc """
  A composable middleware chain for data processing pipelines. Middleware
  modules are stacked using `use Pipeline.Middleware` and executed in
  declaration order, each receiving the accumulated context and a `next`
  function to delegate to the remaining chain. This mirrors the Plug
  pipeline model but operates on arbitrary domain contexts rather than
  HTTP connections, making it suitable for ETL stages, command handlers,
  and business rule evaluation.
  """

  @type context :: map()
  @type next :: (context() -> {:ok, context()} | {:error, term()})
  @type result :: {:ok, context()} | {:error, term()}

  @callback call(context(), next()) :: result()

  defmacro __using__(_opts) do
    quote do
      @behaviour Pipeline.Middleware

      def call(ctx, next), do: next.(ctx)
      defoverridable call: 2
    end
  end

  @doc """
  Builds a composed pipeline from a list of middleware modules and returns
  a single callable function. The pipeline is invoked by passing an initial
  context map.

  ## Example

      run = Pipeline.Middleware.build([
        MyApp.Middleware.Authenticate,
        MyApp.Middleware.Validate,
        MyApp.Middleware.Enrich
      ])

      run.(%{raw_payload: data})
  """
  @spec build([module()]) :: (context() -> result())
  def build(middlewares) when is_list(middlewares) do
    terminal = fn ctx -> {:ok, ctx} end

    Enum.reduce_right(middlewares, terminal, fn middleware_mod, next ->
      fn ctx -> middleware_mod.call(ctx, next) end
    end)
  end

  @doc """
  Runs `middlewares` against `initial_context`. Convenience wrapper around
  `build/1` for one-off pipeline executions.
  """
  @spec run(context(), [module()]) :: result()
  def run(initial_context, middlewares) when is_map(initial_context) do
    build(middlewares).(initial_context)
  end
end

defmodule Commerce.Pipeline.ValidateOrder do
  @moduledoc "Validates the order payload in the processing pipeline."
  use Pipeline.Middleware

  @impl Pipeline.Middleware
  def call(%{order: order} = ctx, next) do
    case Commerce.OrderValidator.validate(order) do
      {:ok, validated_ctx} ->
        next.(%{ctx | order: Map.put(order, :validated, true), validation: validated_ctx})

      {:error, reason} ->
        {:error, {:validation_failed, reason}}
    end
  end

  def call(_ctx, _next), do: {:error, :missing_order}
end

defmodule Commerce.Pipeline.EnrichWithCustomer do
  @moduledoc "Loads and caches the customer record for downstream middleware."
  use Pipeline.Middleware

  @impl Pipeline.Middleware
  def call(%{order: %{customer_id: customer_id}} = ctx, next) do
    case MyApp.Accounts.fetch_customer(customer_id) do
      {:ok, customer} ->
        next.(Map.put(ctx, :customer, customer))

      {:error, :not_found} ->
        {:error, {:customer_not_found, customer_id}}
    end
  end
end

defmodule Commerce.Pipeline.ApplyPricingRules do
  @moduledoc "Applies active pricing rules to the order before fulfilment."
  use Pipeline.Middleware

  @impl Pipeline.Middleware
  def call(%{order: order, customer: customer} = ctx, next) do
    adjusted_order = Commerce.PricingEngine.apply(order, customer)
    next.(%{ctx | order: adjusted_order})
  end
end

defmodule Commerce.Pipeline.CheckFraud do
  @moduledoc "Runs the fraud detection heuristics and halts on high-risk orders."
  use Pipeline.Middleware

  @impl Pipeline.Middleware
  def call(%{order: order, customer: customer} = ctx, next) do
    case Fraud.Detector.evaluate(order, customer) do
      {:ok, :low_risk} ->
        next.(ctx)

      {:ok, :medium_risk} ->
        next.(Map.put(ctx, :fraud_flag, :review))

      {:ok, :high_risk} ->
        {:error, {:fraud_detected, :high_risk}}
    end
  end
end
```
