```elixir
defmodule Saga.Step do
  @moduledoc """
  Defines a single named step in a saga, with a forward action and
  an optional compensating action.
  """

  @type action :: (map() -> {:ok, map()} | {:error, term()})
  @type compensation :: (map() -> :ok)

  @type t :: %__MODULE__{
          name: atom(),
          run: action(),
          compensate: compensation() | nil
        }

  defstruct [:name, :run, :compensate]

  @spec new(atom(), action(), compensation() | nil) :: t()
  def new(name, run_fn, compensate_fn \\ nil)
      when is_atom(name) and is_function(run_fn, 1) do
    compensate_fn = if is_function(compensate_fn, 1), do: compensate_fn, else: nil
    %__MODULE__{name: name, run: run_fn, compensate: compensate_fn}
  end
end

defmodule Saga.Result do
  @moduledoc false

  @type t :: %__MODULE__{
          status: :completed | :compensated,
          context: map(),
          completed_steps: [atom()],
          failed_step: atom() | nil,
          failure_reason: term() | nil
        }

  defstruct [:status, :context, :completed_steps, :failed_step, :failure_reason]
end

defmodule Saga do
  @moduledoc """
  Executes an ordered list of saga steps and coordinates compensation on failure.

  Steps execute sequentially, each receiving and enriching a shared context map.
  If any step fails, previously completed steps are compensated in reverse order
  before the saga result is returned. This ensures external side effects can be
  reversed without relying on distributed transactions.
  """

  alias Saga.{Result, Step}

  @spec run([Step.t()], map()) :: {:ok, Result.t()} | {:error, Result.t()}
  def run(steps, initial_context \\ %{}) when is_list(steps) and is_map(initial_context) do
    execute(steps, initial_context, [])
  end

  defp execute([], context, completed) do
    result = %Result{
      status: :completed,
      context: context,
      completed_steps: Enum.reverse(completed),
      failed_step: nil,
      failure_reason: nil
    }

    {:ok, result}
  end

  defp execute([%Step{} = step | remaining], context, completed) do
    case step.run.(context) do
      {:ok, updated_context} ->
        execute(remaining, updated_context, [step | completed])

      {:error, reason} ->
        compensate(completed, context)

        result = %Result{
          status: :compensated,
          context: context,
          completed_steps: Enum.reverse(completed) |> Enum.map(& &1.name),
          failed_step: step.name,
          failure_reason: reason
        }

        {:error, result}
    end
  end

  defp compensate(completed_steps, context) do
    completed_steps
    |> Enum.filter(fn %Step{compensate: c} -> not is_nil(c) end)
    |> Enum.each(fn %Step{compensate: compensate_fn} -> compensate_fn.(context) end)
  end
end
```
