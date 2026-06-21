```elixir
defmodule Pipeline.Step do
  @moduledoc """
  Behaviour for a single stage in a composable data-transformation pipeline.

  Each step receives and returns a context map. Returning `{:ok, context}`
  advances the pipeline; `{:error, reason}` halts it. Implementing modules
  declare `step_name/0` for telemetry labelling and implement `call/1`
  for the transformation logic.
  """

  @callback step_name() :: atom()
  @callback call(context :: map()) :: {:ok, map()} | {:error, term()}
end

defmodule Pipeline.Runner do
  @moduledoc """
  Executes an ordered list of pipeline steps, emitting telemetry events
  for each stage and short-circuiting on the first failure.

  Each step is timed individually. Telemetry events carry the step name,
  wall-clock duration, and the error reason on failure, giving operators
  per-step latency visibility without coupling step modules to observability
  concerns.
  """

  @type step_module :: module()
  @type pipeline_error :: {:error, {atom(), term()}}

  @spec run([step_module()], map()) :: {:ok, map()} | pipeline_error()
  def run(steps, initial_context \\ %{})
      when is_list(steps) and is_map(initial_context) do
    Enum.reduce_while(steps, {:ok, initial_context}, fn step_module, {:ok, ctx} ->
      case execute_step(step_module, ctx) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, {step_module.step_name(), reason}}}
      end
    end)
  end

  defp execute_step(step_module, context) do
    name = step_module.step_name()
    start = System.monotonic_time()

    result = step_module.call(context)

    duration = System.monotonic_time() - start
    emit_telemetry(name, duration, result)

    result
  end

  defp emit_telemetry(name, duration_native, {:ok, _}) do
    :telemetry.execute(
      [:pipeline, :step, :stop],
      %{duration: duration_native},
      %{step: name, status: :ok}
    )
  end

  defp emit_telemetry(name, duration_native, {:error, reason}) do
    :telemetry.execute(
      [:pipeline, :step, :exception],
      %{duration: duration_native},
      %{step: name, status: :error, reason: inspect(reason)}
    )
  end
end

defmodule Pipeline.Steps.ValidateInput do
  @moduledoc false

  @behaviour Pipeline.Step

  @impl Pipeline.Step
  def step_name, do: :validate_input

  @impl Pipeline.Step
  def call(%{raw_input: input} = context) when is_map(input) do
    case validate(input) do
      :ok -> {:ok, Map.put(context, :validated_input, input)}
      {:error, reason} -> {:error, reason}
    end
  end

  def call(_context), do: {:error, :missing_raw_input}

  defp validate(%{"id" => id}) when is_binary(id) and id != "", do: :ok
  defp validate(_), do: {:error, :missing_required_id_field}
end

defmodule Pipeline.Steps.EnrichData do
  @moduledoc false

  @behaviour Pipeline.Step

  @impl Pipeline.Step
  def step_name, do: :enrich_data

  @impl Pipeline.Step
  def call(%{validated_input: input} = context) do
    enriched = Map.merge(input, %{"processed_at" => DateTime.to_iso8601(DateTime.utc_now())})
    {:ok, Map.put(context, :enriched_data, enriched)}
  end

  def call(_context), do: {:error, :missing_validated_input}
end
```
