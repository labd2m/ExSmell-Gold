```elixir
defmodule MyApp.Workflows.WorkflowEngine do
  @moduledoc """
  Executes configurable multi-step business workflows.
  Workflow definitions are stored in the database as JSON and describe
  states, transitions, guards, and side-effect hooks for processes such
  as contract approvals, onboarding flows, and procurement cycles.
  """

  require Logger

  alias MyApp.Workflows.{WorkflowInstance, WorkflowDefinition, WorkflowRepo, HookRunner}
  alias MyApp.Accounts.User

  @doc """
  Starts a new workflow instance for the given definition ID and subject.
  """
  @spec start(String.t(), String.t(), User.t()) :: {:ok, WorkflowInstance.t()} | {:error, term()}
  def start(definition_id, subject_id, %User{} = initiator) do
    with {:ok, definition} <- WorkflowRepo.get_definition(definition_id),
         {:ok, initial_state} <- resolve_initial_state(definition) do
      instance = %WorkflowInstance{
        id: MyApp.UUID.generate(),
        definition_id: definition_id,
        subject_id: subject_id,
        initiated_by: initiator.id,
        current_state: initial_state,
        history: [],
        started_at: DateTime.utc_now()
      }

      with {:ok, saved} <- WorkflowRepo.insert(instance),
           :ok <- HookRunner.on_enter(saved, initial_state, %{}) do
        Logger.info("Workflow started", instance_id: saved.id, state: initial_state)
        {:ok, saved}
      end
    end
  end

  @doc """
  Transitions a workflow instance to a new state via the named event.
  Validates guards and runs entry/exit hooks.
  """
  @spec transition(WorkflowInstance.t(), String.t(), map()) ::
          {:ok, WorkflowInstance.t()} | {:error, term()}
  def transition(%WorkflowInstance{} = instance, event_name, context \\ %{}) do
    with {:ok, definition} <- WorkflowRepo.get_definition(instance.definition_id),
         {:ok, target_state_str} <- find_target_state(definition, instance.current_state, event_name),
         :ok <- evaluate_guards(definition, instance.current_state, event_name, context),
         :ok <- HookRunner.on_exit(instance, instance.current_state, context),
         {:ok, updated} <- apply_transition(instance, target_state_str),
         :ok <- HookRunner.on_enter(updated, updated.current_state, context) do
      Logger.info("Workflow transitioned",
        instance_id: instance.id,
        from: instance.current_state,
        to: updated.current_state,
        event: event_name
      )

      {:ok, updated}
    else
      {:error, :no_transition} ->
        Logger.warning("No transition found",
          instance_id: instance.id,
          state: instance.current_state,
          event: event_name
        )

        {:error, :no_transition}

      {:error, {:guard_failed, guard}} ->
        Logger.info("Transition blocked by guard",
          instance_id: instance.id,
          guard: guard,
          event: event_name
        )

        {:error, {:guard_failed, guard}}

      {:error, reason} = err ->
        Logger.error("Workflow transition error", reason: inspect(reason))
        err
    end
  end

  defp apply_transition(%WorkflowInstance{} = instance, target_state_str) do
    target_state = String.to_atom(target_state_str)

    history_entry = %{
      from: instance.current_state,
      to: target_state,
      at: DateTime.utc_now()
    }

    updated = %{
      instance
      | current_state: target_state,
        history: [history_entry | instance.history],
        updated_at: DateTime.utc_now()
    }

    WorkflowRepo.update(updated)
  end

  defp resolve_initial_state(%WorkflowDefinition{states: states}) do
    case Enum.find(states, &Map.get(&1, "initial", false)) do
      nil -> {:error, :no_initial_state}
      state -> {:ok, state["name"]}
    end
  end

  defp find_target_state(%WorkflowDefinition{transitions: transitions}, current_state, event) do
    match =
      Enum.find(transitions, fn t ->
        t["from"] == Atom.to_string(current_state) && t["event"] == event
      end)

    case match do
      nil -> {:error, :no_transition}
      t -> {:ok, t["to"]}
    end
  end

  defp evaluate_guards(%WorkflowDefinition{guards: guards}, current_state, event, context) do
    applicable =
      Enum.filter(guards, fn g ->
        g["state"] == Atom.to_string(current_state) && g["event"] == event
      end)

    Enum.reduce_while(applicable, :ok, fn guard, :ok ->
      module = Module.concat([MyApp, Workflows, Guards, Macro.camelize(guard["module"])])

      if function_exported?(module, :check, 1) do
        case module.check(context) do
          :ok -> {:cont, :ok}
          {:error, _} -> {:halt, {:error, {:guard_failed, guard["name"]}}}
        end
      else
        {:cont, :ok}
      end
    end)
  end
end
```
