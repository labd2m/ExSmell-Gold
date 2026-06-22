```elixir
defmodule Commands.Behaviour do
  @moduledoc """
  Behaviour that all command handler modules must implement.
  Each handler is responsible for a single command type.
  """

  @callback handle(command :: struct(), context :: map()) ::
              {:ok, term()} | {:error, term()}

  @callback validate(command :: struct()) ::
              :ok | {:error, [String.t()]}
end

defmodule Commands.Dispatcher do
  @moduledoc """
  Routes validated commands to their registered handler modules.
  Validation always precedes execution; failed validations are returned
  without invoking the handler.
  """

  @type handler_map :: %{module() => module()}

  @spec dispatch(struct(), handler_map(), map()) ::
          {:ok, term()} | {:error, :no_handler | :validation_failed | term()}
  def dispatch(command, handlers, context \\ %{})
      when is_struct(command) and is_map(handlers) and is_map(context) do
    command_type = command.__struct__

    case Map.fetch(handlers, command_type) do
      :error ->
        {:error, :no_handler}

      {:ok, handler} ->
        with :ok <- handler.validate(command) do
          handler.handle(command, context)
        else
          {:error, errors} -> {:error, {:validation_failed, errors}}
        end
    end
  end
end

defmodule Commands.CreateProject do
  @moduledoc "Command to create a new project within a workspace."

  @type t :: %__MODULE__{
          workspace_id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          owner_id: String.t()
        }

  defstruct [:workspace_id, :name, :description, :owner_id]
end

defmodule Commands.Handlers.CreateProject do
  @behaviour Commands.Behaviour

  alias Commands.CreateProject
  alias MyApp.Projects
  alias MyApp.Projects.Project

  @moduledoc "Handles the `Commands.CreateProject` command."

  @impl Commands.Behaviour
  def validate(%CreateProject{workspace_id: wid, name: name, owner_id: oid}) do
    errors =
      []
      |> check_presence("workspace_id", wid)
      |> check_presence("name", name)
      |> check_length("name", name, 2, 100)
      |> check_presence("owner_id", oid)

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  @impl Commands.Behaviour
  def handle(%CreateProject{} = cmd, context) do
    Projects.create_project(%{
      workspace_id: cmd.workspace_id,
      name: cmd.name,
      description: cmd.description,
      owner_id: cmd.owner_id,
      created_by_ip: Map.get(context, :remote_ip)
    })
  end

  defp check_presence(errors, _field, value) when is_binary(value) and value != "", do: errors
  defp check_presence(errors, field, _), do: errors ++ ["#{field} is required"]

  defp check_length(errors, field, value, min, max) when is_binary(value) do
    len = String.length(value)

    cond do
      len < min -> errors ++ ["#{field} must be at least #{min} characters"]
      len > max -> errors ++ ["#{field} must be at most #{max} characters"]
      true -> errors
    end
  end

  defp check_length(errors, _field, _value, _min, _max), do: errors
end
```
