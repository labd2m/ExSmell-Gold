```elixir
defmodule CommandBus.Handler do
  @moduledoc """
  Behaviour that all command handler modules must implement.

  Each handler declares the command struct it accepts via `command/0`
  and executes the business operation in `handle/1`. Returning
  `{:ok, result}` signals success; `{:error, reason}` signals a
  domain-level failure that should be surfaced to the caller.
  """

  @callback command() :: module()
  @callback handle(command :: struct()) :: {:ok, term()} | {:error, term()}
end

defmodule CommandBus do
  @moduledoc """
  Dispatches command structs to their registered handlers.

  Handlers are registered at startup by passing a list of handler modules.
  The bus resolves the correct handler at dispatch time by matching the
  command struct's module against each handler's `command/0` declaration.
  Unknown commands return a typed error rather than raising.
  """

  use GenServer

  @type opts :: [handlers: [module()]]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec dispatch(struct()) :: {:ok, term()} | {:error, :no_handler | term()}
  def dispatch(%_{} = command) do
    GenServer.call(__MODULE__, {:dispatch, command})
  end

  @impl GenServer
  def init(opts) do
    registry =
      opts
      |> Keyword.get(:handlers, [])
      |> Map.new(fn handler -> {handler.command(), handler} end)

    {:ok, %{registry: registry}}
  end

  @impl GenServer
  def handle_call({:dispatch, command}, _from, state) do
    command_module = command.__struct__

    reply =
      case Map.fetch(state.registry, command_module) do
        {:ok, handler} -> handler.handle(command)
        :error -> {:error, :no_handler}
      end

    {:reply, reply, state}
  end
end

defmodule Accounts.Commands.RegisterUser do
  @moduledoc false

  @type t :: %__MODULE__{
          email: String.t(),
          display_name: String.t(),
          role: :admin | :member | :viewer
        }

  defstruct [:email, :display_name, role: :member]
end

defmodule Accounts.Handlers.RegisterUserHandler do
  @moduledoc false

  @behaviour CommandBus.Handler

  alias Accounts.Commands.RegisterUser

  @impl CommandBus.Handler
  def command, do: RegisterUser

  @impl CommandBus.Handler
  def handle(%RegisterUser{} = cmd) do
    Accounts.register_user(%{
      email: cmd.email,
      display_name: cmd.display_name,
      role: cmd.role
    })
  end
end

defmodule Accounts.Commands.DeactivateUser do
  @moduledoc false

  @type t :: %__MODULE__{user_id: String.t(), reason: String.t()}

  defstruct [:user_id, :reason]
end

defmodule Accounts.Handlers.DeactivateUserHandler do
  @moduledoc false

  @behaviour CommandBus.Handler

  alias Accounts.Commands.DeactivateUser

  @impl CommandBus.Handler
  def command, do: DeactivateUser

  @impl CommandBus.Handler
  def handle(%DeactivateUser{user_id: user_id}) do
    with {:ok, user} <- Accounts.get_user(user_id) do
      Accounts.deactivate_user(user)
    end
  end
end
```
