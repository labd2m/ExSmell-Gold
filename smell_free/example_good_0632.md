```elixir
defmodule Data.TransformationPipeline do
  @moduledoc """
  Composes ordered data transformation steps into a single reusable pipeline.
  Each step is defined as a module implementing the `Data.Transform` behaviour.
  The pipeline accumulates transformed data and per-step metadata, making it
  easy to trace which step altered a record and by how much. Steps may
  be marked optional so a failure skips rather than halts the pipeline.
  """

  @type step_def :: %{
          name: atom(),
          module: module(),
          optional: boolean()
        }

  @type step_result :: %{
          name: atom(),
          status: :applied | :skipped | :failed,
          duration_us: non_neg_integer(),
          detail: String.t() | nil
        }

  @type pipeline_result :: %{
          data: term(),
          steps: [step_result()],
          success: boolean()
        }

  @doc """
  Executes `steps` sequentially against `initial_data`. Required step
  failures halt the pipeline and mark the result unsuccessful. Optional
  step failures are recorded but execution continues.
  """
  @spec run([step_def()], term()) :: pipeline_result()
  def run(steps, initial_data) when is_list(steps) do
    {final_data, step_results, success} =
      Enum.reduce_while(steps, {initial_data, [], true}, fn step, {data, results, _} ->
        {duration, outcome} = :timer.tc(fn -> apply_step(step.module, data) end)

        step_result = build_step_result(step.name, outcome, duration)

        case {outcome, step.optional} do
          {{:ok, new_data}, _} ->
            {:cont, {new_data, [step_result | results], true}}

          {{:error, _reason}, true} ->
            {:cont, {data, [step_result | results], true}}

          {{:error, _reason}, false} ->
            {:halt, {data, [step_result | results], false}}
        end
      end)

    %{data: final_data, steps: Enum.reverse(step_results), success: success}
  end

  @doc "Returns step results where the status is `:failed`."
  @spec failed_steps(pipeline_result()) :: [step_result()]
  def failed_steps(%{steps: steps}) do
    Enum.filter(steps, fn s -> s.status == :failed end)
  end

  @doc "Returns the total pipeline duration in microseconds."
  @spec total_duration_us(pipeline_result()) :: non_neg_integer()
  def total_duration_us(%{steps: steps}) do
    Enum.sum_by(steps, & &1.duration_us)
  end

  defp apply_step(module, data) do
    module.transform(data)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_step_result(name, {:ok, _new_data}, duration_us) do
    %{name: name, status: :applied, duration_us: duration_us, detail: nil}
  end

  defp build_step_result(name, {:error, reason}, duration_us) do
    %{name: name, status: :failed, duration_us: duration_us, detail: inspect(reason)}
  end
end

defmodule Data.Transform do
  @moduledoc "Behaviour for a single data transformation step."

  @doc "Applies the transformation to `data`. Returns the modified data or an error."
  @callback transform(data :: term()) :: {:ok, term()} | {:error, term()}
end
```
