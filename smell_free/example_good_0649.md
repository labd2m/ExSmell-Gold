```elixir
defmodule Transform.Pipeline do
  @moduledoc """
  Executes a sequence of data transformation steps with structured error
  reporting and optional dry-run mode. Each step is a module implementing
  the `Transform.Step` behaviour. Steps are composable and reusable across
  different pipelines. In dry-run mode the pipeline validates each step
  without committing any mutations, making it safe to preview the outcome
  of an import or migration before applying it.
  """

  alias Transform.Step

  require Logger

  @type step_module :: module()
  @type pipeline_opts :: [dry_run: boolean(), stop_on_error: boolean()]
  @type step_result :: {:ok, term()} | {:error, term()}

  @type run_result :: %{
          status: :completed | :completed_with_errors | :failed,
          step_results: [%{step: binary(), status: :ok | :error, detail: term()}],
          output: term()
        }

  @doc """
  Runs `steps` in order, threading output from each step into the next.
  In `:dry_run` mode steps are validated but mutations are not committed.
  Returns a structured `run_result` map.
  """
  @spec run(term(), [step_module()], pipeline_opts()) :: run_result()
  def run(initial_input, steps, opts \\ [])
      when is_list(steps) do
    dry_run = Keyword.get(opts, :dry_run, false)
    stop_on_error = Keyword.get(opts, :stop_on_error, true)

    context = %{dry_run: dry_run, input: initial_input}

    {final_context, step_results} = execute_steps(steps, context, [], stop_on_error)

    build_result(final_context, step_results)
  end

  # ---------------------------------------------------------------------------
  # Private execution engine
  # ---------------------------------------------------------------------------

  defp execute_steps([], context, results, _stop_on_error) do
    {context, Enum.reverse(results)}
  end

  defp execute_steps([step_mod | remaining], context, results, stop_on_error) do
    step_name = step_mod |> Module.split() |> List.last()

    Logger.debug("Running pipeline step", step: step_name, dry_run: context.dry_run)

    outcome =
      if context.dry_run do
        Step.validate(step_mod, context.input, context)
      else
        Step.execute(step_mod, context.input, context)
      end

    case outcome do
      {:ok, output} ->
        result = %{step: step_name, status: :ok, detail: nil}
        new_context = %{context | input: output}
        execute_steps(remaining, new_context, [result | results], stop_on_error)

      {:error, reason} ->
        result = %{step: step_name, status: :error, detail: reason}

        Logger.warning("Pipeline step failed",
          step: step_name,
          reason: inspect(reason),
          dry_run: context.dry_run
        )

        if stop_on_error do
          {context, Enum.reverse([result | results])}
        else
          execute_steps(remaining, context, [result | results], stop_on_error)
        end
    end
  end

  defp build_result(context, step_results) do
    has_errors = Enum.any?(step_results, &(&1.status == :error))
    last_ok = Enum.find(Enum.reverse(step_results), &(&1.status == :ok))

    status =
      cond do
        last_ok == nil and has_errors -> :failed
        has_errors -> :completed_with_errors
        true -> :completed
      end

    %{status: status, step_results: step_results, output: context.input}
  end
end

defmodule Transform.Step do
  @moduledoc """
  Behaviour for individual pipeline step modules.
  """

  @doc "Validates that the step can be applied to `input` without mutating anything."
  @callback validate(input :: term(), context :: map()) :: {:ok, term()} | {:error, term()}

  @doc "Applies the transformation to `input`, committing any mutations."
  @callback execute(input :: term(), context :: map()) :: {:ok, term()} | {:error, term()}

  @doc "Delegates to `validate/2` or `execute/2` based on the step module."
  @spec validate(module(), term(), map()) :: {:ok, term()} | {:error, term()}
  def validate(mod, input, context), do: mod.validate(input, context)

  @spec execute(module(), term(), map()) :: {:ok, term()} | {:error, term()}
  def execute(mod, input, context), do: mod.execute(input, context)
end
```
