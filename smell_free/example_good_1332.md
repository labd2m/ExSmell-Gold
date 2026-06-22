```elixir
defmodule Cqrs.CommandBus do
  @moduledoc """
  Dispatches typed commands through a configurable middleware chain to
  registered command handlers.

  Middleware modules run in declaration order, each able to transform the
  command or short-circuit dispatch. The handler is invoked as the innermost
  step after all middleware has passed.
  """

  alias Cqrs.CommandBus.{HandlerRegistry, Middleware, DispatchContext}

  @doc """
  Dispatches a command struct through the middleware chain to its handler.

  Returns the handler's result or an error from middleware/dispatch.
  """
  @spec dispatch(struct(), [module()], keyword()) :: {:ok, term()} | {:error, term()}
  def dispatch(%_{} = command, middleware_chain \\ [], opts \\ [])
      when is_list(middleware_chain) do
    handler = HandlerRegistry.lookup(command.__struct__)

    case handler do
      nil ->
        {:error, "no handler registered for #{inspect(command.__struct__)}"}

      handler_module ->
        ctx = DispatchContext.new(command, handler_module, opts)
        run_chain(ctx, middleware_chain)
    end
  end

  defp run_chain(ctx, []) do
    ctx.handler.handle(ctx.command)
  end

  defp run_chain(ctx, [middleware | rest]) do
    Middleware.call(middleware, ctx, fn updated_ctx ->
      run_chain(updated_ctx, rest)
    end)
  end
end

defmodule Cqrs.CommandBus.Middleware do
  @moduledoc "Behaviour for command bus middleware."

  alias Cqrs.CommandBus.DispatchContext

  @type next :: (DispatchContext.t() -> {:ok, term()} | {:error, term()})

  @callback call(DispatchContext.t(), next()) :: {:ok, term()} | {:error, term()}

  @spec call(module(), DispatchContext.t(), next()) :: {:ok, term()} | {:error, term()}
  def call(middleware_module, ctx, next), do: middleware_module.call(ctx, next)
end

defmodule Cqrs.CommandBus.DispatchContext do
  @moduledoc "Carries command and handler through the middleware chain."

  @enforce_keys [:command, :handler, :metadata]
  defstruct [:command, :handler, :metadata]

  @type t :: %__MODULE__{command: struct(), handler: module(), metadata: map()}

  @spec new(struct(), module(), keyword()) :: t()
  def new(command, handler, opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    %__MODULE__{command: command, handler: handler, metadata: metadata}
  end
end

defmodule Cqrs.CommandBus.HandlerRegistry do
  @moduledoc "Maintains the mapping from command struct modules to handler modules."

  use Agent

  @doc false
  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc """
  Registers a handler module for a command struct type.
  """
  @spec register(module(), module()) :: :ok
  def register(command_module, handler_module)
      when is_atom(command_module) and is_atom(handler_module) do
    Agent.update(__MODULE__, &Map.put(&1, command_module, handler_module))
  end

  @doc """
  Looks up the handler for a command module, returning nil if unregistered.
  """
  @spec lookup(module()) :: module() | nil
  def lookup(command_module) when is_atom(command_module) do
    Agent.get(__MODULE__, &Map.get(&1, command_module))
  end
end

defmodule Cqrs.Middleware.Logger do
  @moduledoc "Command bus middleware that logs dispatch timing."

  @behaviour Cqrs.CommandBus.Middleware

  require Logger

  alias Cqrs.CommandBus.DispatchContext

  @impl Cqrs.CommandBus.Middleware
  def call(%DispatchContext{command: cmd} = ctx, next) do
    start = System.monotonic_time(:microsecond)
    result = next.(ctx)
    elapsed = System.monotonic_time(:microsecond) - start

    case result do
      {:ok, _} ->
        Logger.debug("command #{inspect(cmd.__struct__)} dispatched in #{elapsed}µs")

      {:error, reason} ->
        Logger.warning("command #{inspect(cmd.__struct__)} failed in #{elapsed}µs: #{inspect(reason)}")
    end

    result
  end
end

defmodule Cqrs.Middleware.Validator do
  @moduledoc "Command bus middleware that validates commands before dispatch."

  @behaviour Cqrs.CommandBus.Middleware

  alias Cqrs.CommandBus.DispatchContext

  @impl Cqrs.CommandBus.Middleware
  def call(%DispatchContext{command: cmd} = ctx, next) do
    if function_exported?(cmd.__struct__, :validate, 1) do
      case cmd.__struct__.validate(cmd) do
        :ok -> next.(ctx)
        {:error, reason} -> {:error, "command validation failed: #{inspect(reason)}"}
      end
    else
      next.(ctx)
    end
  end
end
```
