```elixir
defmodule CQRS.Command do
  @moduledoc """
  Base behaviour and struct convention for application commands.
  Each command is a plain struct with a unique type tag and
  an optional correlation ID for tracing.
  """

  @callback validate(struct()) :: :ok | {:error, list({atom(), String.t()})}

  defmacro __using__(_opts) do
    quote do
      @behaviour CQRS.Command
      defstruct [:correlation_id]
    end
  end
end

defmodule CQRS.CommandBus do
  @moduledoc """
  Routes commands to their registered handlers and wraps execution in
  structured result telemetry. Each command type maps to exactly one
  handler module that implements `CQRS.Handler`.
  """

  require Logger

  alias CQRS.Handler

  @type handler_registry :: %{module() => module()}

  @spec dispatch(struct(), handler_registry()) ::
          {:ok, term()} | {:error, :no_handler} | {:error, term()}
  def dispatch(%{__struct__: command_type} = command, registry) when is_map(registry) do
    case Map.fetch(registry, command_type) do
      {:ok, handler_module} -> execute(command, handler_module)
      :error -> {:error, :no_handler}
    end
  end

  defp execute(command, handler_module) do
    start = System.monotonic_time(:microsecond)
    command_name = command.__struct__ |> Module.split() |> List.last()

    result =
      with :ok <- handler_module.validate(command) do
        handler_module.handle(command)
      end

    duration_us = System.monotonic_time(:microsecond) - start

    :telemetry.execute(
      [:cqrs, :command, :dispatched],
      %{duration_us: duration_us},
      %{command: command_name, success: match?({:ok, _}, result)}
    )

    Logger.debug("Command dispatched", command: command_name, duration_us: duration_us)
    result
  end
end

defmodule CQRS.Handler do
  @moduledoc """
  Behaviour for command handlers. Each handler validates, then processes
  a single command type.
  """

  @callback validate(struct()) :: :ok | {:error, list({atom(), String.t()})}
  @callback handle(struct()) :: {:ok, term()} | {:error, term()}
end

defmodule CQRS.Registry do
  @moduledoc """
  A supervised GenServer holding the live command-to-handler mapping.
  Handlers are registered at startup and may be added at runtime for
  plugin-style extensibility.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    initial = Keyword.get(opts, :handlers, %{})
    GenServer.start_link(__MODULE__, initial, name: __MODULE__)
  end

  @spec register(module(), module()) :: :ok
  def register(command_type, handler_module)
      when is_atom(command_type) and is_atom(handler_module) do
    GenServer.cast(__MODULE__, {:register, command_type, handler_module})
  end

  @spec dispatch(struct()) :: {:ok, term()} | {:error, atom()} | {:error, term()}
  def dispatch(command) when is_struct(command) do
    registry = GenServer.call(__MODULE__, :registry)
    CQRS.CommandBus.dispatch(command, registry)
  end

  @spec all_handlers() :: %{module() => module()}
  def all_handlers do
    GenServer.call(__MODULE__, :registry)
  end

  @impl GenServer
  def init(initial_registry) when is_map(initial_registry) do
    {:ok, initial_registry}
  end

  @impl GenServer
  def handle_cast({:register, command_type, handler_module}, registry) do
    {:noreply, Map.put(registry, command_type, handler_module)}
  end

  @impl GenServer
  def handle_call(:registry, _from, registry) do
    {:reply, registry, registry}
  end
end
```
