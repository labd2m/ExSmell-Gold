**File:** `example_good_1398.md`

```elixir
defmodule CommandBus.Command do
  @moduledoc "Marker behaviour for command structs dispatched through the bus."

  @doc "Returns the unique string type identifier for this command."
  @callback command_type() :: String.t()
end

defmodule CommandBus.Handler do
  @moduledoc "Behaviour for command handlers registered with the bus."

  @doc "Handles the given command. Returns {:ok, result} or {:error, reason}."
  @callback handle(struct()) :: {:ok, term()} | {:error, term()}
end

defmodule CommandBus.Middleware do
  @moduledoc "Behaviour for command bus middleware steps."

  @doc """
  Processes a command and calls `next.(command)` to continue the chain.
  May return early with an error without calling next.
  """
  @callback call(struct(), (struct() -> {:ok, term()} | {:error, term()})) ::
              {:ok, term()} | {:error, term()}
end

defmodule CommandBus.Middleware.Logger do
  @moduledoc "Logs command dispatch timing and outcomes."

  @behaviour CommandBus.Middleware

  require Logger

  @impl CommandBus.Middleware
  def call(command, next) do
    type = command.__struct__ |> Module.split() |> List.last()
    started_at = System.monotonic_time(:millisecond)

    result = next.(command)

    elapsed = System.monotonic_time(:millisecond) - started_at

    case result do
      {:ok, _} ->
        Logger.debug("Command #{type} succeeded in #{elapsed}ms")

      {:error, reason} ->
        Logger.warning("Command #{type} failed in #{elapsed}ms: #{inspect(reason)}")
    end

    result
  end
end

defmodule CommandBus.Middleware.Validator do
  @moduledoc "Validates that the command struct has all required fields populated."

  @behaviour CommandBus.Middleware

  @impl CommandBus.Middleware
  def call(command, next) do
    fields = Map.from_struct(command)
    missing = Enum.filter(fields, fn {_k, v} -> is_nil(v) end) |> Keyword.keys()

    if missing == [] do
      next.(command)
    else
      {:error, {:missing_required_fields, missing}}
    end
  end
end

defmodule CommandBus do
  @moduledoc """
  Dispatches commands to registered handlers through a configurable
  middleware chain. Handlers are registered by command module at startup.
  """

  use Agent

  alias CommandBus.{Handler, Middleware}

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    initial = %{handlers: %{}, middlewares: Keyword.get(opts, :middlewares, [])}
    Agent.start_link(fn -> initial end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec register_handler(module(), module()) :: :ok
  def register_handler(command_module, handler_module)
      when is_atom(command_module) and is_atom(handler_module) do
    Agent.update(__MODULE__, fn state ->
      %{state | handlers: Map.put(state.handlers, command_module, handler_module)}
    end)
  end

  @spec dispatch(struct()) :: {:ok, term()} | {:error, term()}
  def dispatch(%_{} = command) do
    %{handlers: handlers, middlewares: middlewares} = Agent.get(__MODULE__, & &1)

    case Map.fetch(handlers, command.__struct__) do
      {:ok, handler} ->
        execute_with_middleware(command, handler, middlewares)

      :error ->
        {:error, {:no_handler_registered, command.__struct__}}
    end
  end

  defp execute_with_middleware(command, handler, middlewares) do
    terminal = fn cmd -> handler.handle(cmd) end

    pipeline =
      Enum.reduce(Enum.reverse(middlewares), terminal, fn middleware, next ->
        fn cmd -> middleware.call(cmd, next) end
      end)

    pipeline.(command)
  end
end
```
