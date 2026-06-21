```elixir
defmodule Platform.CommandDispatcher do
  @moduledoc """
  A command dispatcher for CQRS-style architectures.

  Commands are plain structs. Each command type maps to exactly one handler
  module that implements the `Platform.CommandHandler` behaviour. The
  dispatcher validates the command, delegates to the handler, and emits
  Telemetry events for observability.
  """

  alias Platform.CommandDispatcher.Registry

  @type command :: struct()
  @type dispatch_result :: {:ok, term()} | {:error, term()}

  @doc """
  Dispatches a command struct to its registered handler.

  Emits `[:platform, :command, :start]` and `[:platform, :command, :stop]`
  Telemetry events with the command module and result metadata.
  """
  @spec dispatch(command()) :: dispatch_result()
  def dispatch(%_{} = command) do
    command_module = command.__struct__

    with {:ok, handler} <- Registry.handler_for(command_module),
         :ok <- validate(command, handler) do
      execute(command, handler, command_module)
    end
  end

  defp validate(command, handler) do
    if function_exported?(handler, :validate, 1) do
      handler.validate(command)
    else
      :ok
    end
  end

  defp execute(command, handler, command_module) do
    start_time = System.monotonic_time()
    metadata = %{command: command_module}
    :telemetry.execute([:platform, :command, :start], %{system_time: System.system_time()}, metadata)

    result = handler.handle(command)

    duration = System.monotonic_time() - start_time
    status = if match?({:ok, _}, result), do: :ok, else: :error
    :telemetry.execute([:platform, :command, :stop], %{duration: duration}, Map.put(metadata, :status, status))

    result
  end
end

defmodule Platform.CommandDispatcher.Registry do
  @moduledoc """
  Maintains the mapping from command struct modules to their handler modules.
  """

  @type command_module :: module()
  @type handler_module :: module()

  @spec handler_for(command_module()) :: {:ok, handler_module()} | {:error, :no_handler}
  def handler_for(command_module) when is_atom(command_module) do
    case Application.get_env(:platform, :command_handlers, %{})[command_module] do
      nil -> {:error, :no_handler}
      handler -> {:ok, handler}
    end
  end
end

defmodule Platform.CommandHandler do
  @moduledoc """
  Behaviour that all command handler modules must implement.
  """

  @doc "Executes the command. Must return `{:ok, result}` or `{:error, reason}`."
  @callback handle(command :: struct()) :: {:ok, term()} | {:error, term()}

  @doc "Optional validation of the command before execution."
  @callback validate(command :: struct()) :: :ok | {:error, term()}

  @optional_callbacks validate: 1
end

defmodule Platform.Commands.CreateProject do
  @moduledoc "Command for creating a new project within a workspace."

  @type t :: %__MODULE__{
          workspace_id: pos_integer(),
          name: String.t(),
          visibility: :public | :private,
          owner_id: pos_integer()
        }

  defstruct [:workspace_id, :name, :owner_id, visibility: :private]
end

defmodule Platform.Handlers.CreateProjectHandler do
  @moduledoc "Handles the `CreateProject` command."

  @behaviour Platform.CommandHandler

  alias Platform.Projects
  alias Platform.Commands.CreateProject

  @impl Platform.CommandHandler
  def validate(%CreateProject{name: name}) when byte_size(name) < 2 do
    {:error, {:validation, :name_too_short}}
  end

  def validate(%CreateProject{}), do: :ok

  @impl Platform.CommandHandler
  def handle(%CreateProject{} = cmd) do
    Projects.create(%{
      workspace_id: cmd.workspace_id,
      name: cmd.name,
      visibility: cmd.visibility,
      owner_id: cmd.owner_id
    })
  end
end
```
