```elixir
defmodule Interceptor do
  @moduledoc """
  Behaviour for a single function-call interceptor.

  Interceptors wrap a `next` continuation in the same way Plugs wrap
  `conn`, but for arbitrary domain function calls rather than HTTP
  requests. Each interceptor receives a context map and a zero-arity
  `next` function. Calling `next.()` delegates to the remaining chain;
  not calling it short-circuits execution. The return value of `call/2`
  becomes the result seen by the caller.
  """

  @type context :: map()
  @type next :: (-> {:ok, term()} | {:error, term()})

  @callback call(context(), next()) :: {:ok, term()} | {:error, term()}
end

defmodule Interceptor.Chain do
  @moduledoc """
  Composes a list of interceptors around a terminal handler function.

  The chain is built right-to-left so the first interceptor in the list
  is the outermost wrapper. Each interceptor can inspect and mutate the
  context map, short-circuit by returning early, or perform post-processing
  on the result returned by `next.()`.
  """

  @spec execute([module()], Interceptor.context(), (Interceptor.context() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def execute(interceptors, context, handler)
      when is_list(interceptors) and is_map(context) and is_function(handler, 1) do
    chain = build_chain(interceptors, handler)
    chain.(context)
  end

  defp build_chain([], handler), do: handler

  defp build_chain([interceptor | rest], handler) do
    inner = build_chain(rest, handler)

    fn ctx ->
      next = fn -> inner.(ctx) end
      interceptor.call(ctx, next)
    end
  end
end

defmodule Interceptor.Timing do
  @moduledoc """
  Records wall-clock duration of the inner chain and emits a telemetry event.
  """

  @behaviour Interceptor

  @impl Interceptor
  def call(context, next) do
    start = System.monotonic_time(:microsecond)
    result = next.()
    duration = System.monotonic_time(:microsecond) - start

    :telemetry.execute(
      [:interceptor, :timing],
      %{duration_us: duration},
      Map.take(context, [:operation, :module])
    )

    result
  end
end

defmodule Interceptor.Logger do
  @moduledoc """
  Logs the start and completion of each operation at the configured level.
  """

  @behaviour Interceptor

  require Logger

  @impl Interceptor
  def call(%{operation: operation} = context, next) do
    Logger.debug("Starting operation", operation: operation)

    case next.() do
      {:ok, _} = ok ->
        Logger.debug("Operation succeeded", operation: operation)
        ok

      {:error, reason} = err ->
        Logger.warning("Operation failed", operation: operation, reason: inspect(reason))
        err
    end
  end

  def call(context, next), do: next.()
end

defmodule Interceptor.Authorizer do
  @moduledoc """
  Checks that the context carries a principal before delegating.
  """

  @behaviour Interceptor

  @impl Interceptor
  def call(%{principal: nil}, _next), do: {:error, :unauthenticated}
  def call(%{principal: _principal}, next), do: next.()
  def call(_context, _next), do: {:error, :unauthenticated}
end

defmodule Interceptor.Retry do
  @moduledoc """
  Retries the inner chain up to `max_attempts` times on transient errors.
  """

  @behaviour Interceptor

  @impl Interceptor
  def call(context, next) do
    max = Map.get(context, :max_retry_attempts, 3)
    do_retry(next, max, 1)
  end

  defp do_retry(next, max, attempt) do
    case next.() do
      {:ok, _} = ok -> ok
      {:error, {:transient, _}} when attempt < max ->
        :timer.sleep(100 * attempt)
        do_retry(next, max, attempt + 1)
      other -> other
    end
  end
end
```
