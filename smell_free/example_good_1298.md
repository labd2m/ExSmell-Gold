**File:** `example_good_1298.md`

```elixir
defmodule Saga.Step do
  @moduledoc """
  Defines a single saga step: a named forward action paired with
  a compensating action to undo it on downstream failure.
  """

  @enforce_keys [:name, :execute, :compensate]
  defstruct [:name, :execute, :compensate]

  @type action :: (map() -> {:ok, map()} | {:error, term()})
  @type t :: %__MODULE__{
          name: atom(),
          execute: action(),
          compensate: action()
        }

  @spec new(atom(), action(), action()) :: t()
  def new(name, execute, compensate)
      when is_atom(name) and is_function(execute, 1) and is_function(compensate, 1) do
    %__MODULE__{name: name, execute: execute, compensate: compensate}
  end
end

defmodule Saga.Result do
  @moduledoc "Represents the outcome of a saga execution."

  @enforce_keys [:status]
  defstruct [:status, :context, :failed_step, :error, :compensated_steps]

  @type status :: :completed | :compensated | :compensation_failed
  @type t :: %__MODULE__{
          status: status(),
          context: map(),
          failed_step: atom() | nil,
          error: term() | nil,
          compensated_steps: [atom()]
        }
end

defmodule Saga.Orchestrator do
  @moduledoc """
  Executes a list of saga steps sequentially. On failure, runs
  compensating actions in reverse order for all completed steps.
  """

  require Logger

  alias Saga.{Result, Step}

  @spec run([Step.t()], map()) :: Result.t()
  def run(steps, initial_context \\ %{}) when is_list(steps) do
    execute_forward(steps, [], initial_context)
  end

  defp execute_forward([], completed, context) do
    %Result{
      status: :completed,
      context: context,
      compensated_steps: [],
      failed_step: nil,
      error: nil
    }
  end

  defp execute_forward([%Step{} = step | remaining], completed, context) do
    Logger.debug("Saga: executing step #{step.name}")

    case step.execute.(context) do
      {:ok, updated_context} ->
        execute_forward(remaining, [step | completed], updated_context)

      {:error, reason} ->
        Logger.warning("Saga: step #{step.name} failed: #{inspect(reason)}, starting compensation")
        compensate(completed, context, step.name, reason)
    end
  end

  defp compensate(completed_steps, context, failed_step, error) do
    {final_status, compensated} =
      Enum.reduce(completed_steps, {:compensated, []}, fn step, {status, done} ->
        Logger.debug("Saga: compensating step #{step.name}")

        case step.compensate.(context) do
          {:ok, _} ->
            {status, [step.name | done]}

          {:error, reason} ->
            Logger.error("Saga: compensation of #{step.name} failed: #{inspect(reason)}")
            {:compensation_failed, [step.name | done]}
        end
      end)

    %Result{
      status: final_status,
      context: context,
      failed_step: failed_step,
      error: error,
      compensated_steps: Enum.reverse(compensated)
    }
  end
end

defmodule Saga do
  @moduledoc "Convenience builder for constructing and running saga definitions."

  alias Saga.{Orchestrator, Step}

  @type step_opts :: [name: atom(), execute: Step.action(), compensate: Step.action()]

  @spec define([step_opts()]) :: [Step.t()]
  def define(step_opts_list) when is_list(step_opts_list) do
    Enum.map(step_opts_list, fn opts ->
      Step.new(
        Keyword.fetch!(opts, :name),
        Keyword.fetch!(opts, :execute),
        Keyword.fetch!(opts, :compensate)
      )
    end)
  end

  @spec run([Step.t()], map()) :: Saga.Result.t()
  defdelegate run(steps, context \\ %{}), to: Orchestrator
end
```
