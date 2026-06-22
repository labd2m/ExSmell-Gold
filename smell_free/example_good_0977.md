```elixir
defmodule Commands.Bus do
  @moduledoc """
  A typed command bus that dispatches commands to registered handlers through
  a configurable middleware pipeline. Commands are plain structs; each command
  module declares its handler via a `@handler` module attribute so the bus can
  resolve handlers at compile time rather than maintaining a runtime registry.
  Middleware modules wrap the dispatch call and are composed in declaration order,
  enabling cross-cutting concerns such as validation, authorisation, logging,
  and transaction wrapping without coupling them to individual handlers.
  """

  require Logger

  @type command :: struct()
  @type middleware :: module()
  @type dispatch_result :: {:ok, term()} | {:error, term()}

  @default_middleware [
    Commands.Middleware.Validate,
    Commands.Middleware.Authorize,
    Commands.Middleware.Telemetry,
    Commands.Middleware.Transaction
  ]

  @doc """
  Dispatches `command` through the middleware stack and to its handler.
  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec dispatch(command(), keyword()) :: dispatch_result()
  def dispatch(command, opts \\ []) when is_struct(command) do
    middleware = Keyword.get(opts, :middleware, @default_middleware)
    actor = Keyword.get(opts, :actor)
    context = %{command: command, actor: actor}

    pipeline = build_pipeline(middleware, &execute_handler/1)
    pipeline.(context)
  end

  @doc """
  Dispatches `command` and raises on failure. Use in contexts where the
  caller guarantees validity, such as migrations or admin scripts.
  """
  @spec dispatch!(command(), keyword()) :: term()
  def dispatch!(command, opts \\ []) do
    case dispatch(command, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise "Command dispatch failed: #{inspect(reason)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_pipeline(middleware_modules, terminal) do
    Enum.reduce_right(middleware_modules, terminal, fn mod, next ->
      fn ctx -> mod.call(ctx, next) end
    end)
  end

  defp execute_handler(%{command: command} = _ctx) do
    handler = resolve_handler(command)

    case handler.handle(command) do
      {:ok, _} = result -> result
      {:error, _} = err -> err
      other -> {:ok, other}
    end
  rescue
    e -> {:error, {:handler_exception, Exception.message(e)}}
  end

  defp resolve_handler(command) do
    schema = command.__struct__

    case :erlang.function_exported(schema, :__handler__, 0) do
      true ->
        schema.__handler__()

      false ->
        raise ArgumentError,
              "No handler registered for command #{inspect(schema)}. " <>
                "Define `@handler MyHandlerModule` in the command module."
    end
  end
end

defmodule Commands.Middleware.Validate do
  @moduledoc "Validates the command struct before dispatching."
  @behaviour Commands.Middleware

  @impl Commands.Middleware
  def call(%{command: command} = ctx, next) do
    case validate(command) do
      :ok -> next.(ctx)
      {:error, reason} -> {:error, {:validation_failed, reason}}
    end
  end

  defp validate(command) do
    schema = command.__struct__

    if :erlang.function_exported(schema, :validate, 1) do
      schema.validate(command)
    else
      :ok
    end
  end
end

defmodule Commands.Middleware.Telemetry do
  @moduledoc "Emits telemetry events around command execution."
  @behaviour Commands.Middleware

  @impl Commands.Middleware
  def call(%{command: command} = ctx, next) do
    start_time = System.monotonic_time()
    command_name = command.__struct__ |> Module.split() |> List.last()

    :telemetry.execute([:commands, :dispatch, :start], %{}, %{command: command_name})

    result = next.(ctx)

    duration = System.monotonic_time() - start_time
    status = if match?({:ok, _}, result), do: :success, else: :failure

    :telemetry.execute(
      [:commands, :dispatch, :stop],
      %{duration: duration},
      %{command: command_name, status: status}
    )

    result
  end
end

defmodule Commands.Middleware do
  @moduledoc "Behaviour for command bus middleware modules."
  @callback call(map(), (map() -> Commands.Bus.dispatch_result())) :: Commands.Bus.dispatch_result()
end

defmodule Commerce.Commands.PlaceOrder do
  @moduledoc "Command to place a new order for a customer."

  @handler Commerce.Handlers.PlaceOrderHandler

  @enforce_keys [:customer_id, :items, :shipping_address]
  defstruct [:customer_id, :items, :shipping_address, coupon_code: nil]

  def __handler__, do: @handler

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{customer_id: id, items: items}) do
    cond do
      not is_binary(id) or byte_size(id) == 0 -> {:error, :invalid_customer_id}
      not is_list(items) or items == [] -> {:error, :no_items}
      true -> :ok
    end
  end
end
```
