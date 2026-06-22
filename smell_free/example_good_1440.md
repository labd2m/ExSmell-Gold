```elixir
defmodule Saga.Orchestrator do
  @moduledoc """
  Executes a sequence of named saga steps with automatic compensating
  transactions on failure. Each step declares a forward action and a
  compensator. On error, all completed steps are rolled back in reverse order.
  """

  @type step_name :: atom()

  @type step :: %{
          name: step_name(),
          action: (map() -> {:ok, map()} | {:error, term()}),
          compensate: (map() -> :ok)
        }

  @type saga_result ::
          {:ok, map()}
          | {:error, %{failed_step: step_name(), reason: term(), compensated: [step_name()]}}

  @spec run([step()], map()) :: saga_result()
  def run(steps, initial_context \\ %{}) when is_list(steps) do
    execute_steps(steps, [], initial_context)
  end

  @spec execute_steps([step()], [step()], map()) :: saga_result()
  defp execute_steps([], _completed, context) do
    {:ok, context}
  end

  defp execute_steps([step | remaining], completed, context) do
    case step.action.(context) do
      {:ok, updated_context} ->
        execute_steps(remaining, [step | completed], updated_context)

      {:error, reason} ->
        compensated = run_compensations(completed, context)

        {:error,
         %{
           failed_step: step.name,
           reason: reason,
           compensated: compensated
         }}
    end
  end

  @spec run_compensations([step()], map()) :: [step_name()]
  defp run_compensations(completed_steps, context) do
    completed_steps
    |> Enum.reduce([], fn step, compensated ->
      step.compensate.(context)
      [step.name | compensated]
    end)
    |> Enum.reverse()
  end

  @spec new_step(step_name(), (map() -> {:ok, map()} | {:error, term()}), (map() -> :ok)) ::
          step()
  def new_step(name, action, compensate \\ fn _ -> :ok end)
      when is_atom(name) and is_function(action, 1) and is_function(compensate, 1) do
    %{name: name, action: action, compensate: compensate}
  end

  @spec run_async([step()], map(), keyword()) :: saga_result()
  def run_async(steps, initial_context \\ %{}, opts \\ []) when is_list(steps) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    ref = make_ref()
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        result = run(steps, initial_context)
        send(parent, {ref, result})
      end)

    receive do
      {^ref, result} -> result
    after
      timeout ->
        Process.exit(pid, :kill)
        {:error, %{failed_step: :timeout, reason: :saga_timed_out, compensated: []}}
    end
  end

  @spec step_names([step()]) :: [step_name()]
  def step_names(steps) when is_list(steps) do
    Enum.map(steps, & &1.name)
  end
end
```
