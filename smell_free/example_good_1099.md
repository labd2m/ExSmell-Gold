```elixir
defmodule Pipeline.Stage do
  @moduledoc """
  Behaviour contract for a single transformation stage in a data pipeline.
  Each stage receives a structured context map and returns an updated one,
  or an error tuple that short-circuits downstream execution.
  """

  @type context :: map()
  @type stage_result :: {:ok, context()} | {:error, term()}

  @callback run(context()) :: stage_result()
end

defmodule Pipeline.Runner do
  @moduledoc """
  Executes an ordered list of pipeline stages sequentially.
  Execution halts immediately on the first stage returning `{:error, reason}`,
  preserving the accumulated context up to that point.
  """

  alias Pipeline.Stage

  @type stage_module :: module()

  @doc """
  Runs all stages in order against the provided initial context.
  Returns `{:ok, final_context}` when every stage succeeds,
  or `{:error, {failed_stage, reason}}` on the first failure.
  """
  @spec run([stage_module()], Stage.context()) ::
          {:ok, Stage.context()} | {:error, {stage_module(), term()}}
  def run(stages, initial_context)
      when is_list(stages) and is_map(initial_context) do
    Enum.reduce_while(stages, {:ok, initial_context}, fn stage, {:ok, ctx} ->
      stage
      |> apply(:run, [ctx])
      |> wrap_result(stage)
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp wrap_result({:ok, ctx}, _stage), do: {:cont, {:ok, ctx}}
  defp wrap_result({:error, reason}, stage), do: {:halt, {:error, {stage, reason}}}
end

defmodule Pipeline.Stages.ValidateSchema do
  @moduledoc "Ensures required top-level keys are present in the pipeline context."

  @behaviour Pipeline.Stage

  @required_keys [:user_id, :payload, :source]

  @impl Pipeline.Stage
  def run(context) when is_map(context) do
    missing = Enum.reject(@required_keys, &Map.has_key?(context, &1))
    validate_keys(missing, context)
  end

  defp validate_keys([], context), do: {:ok, context}
  defp validate_keys(missing, _context), do: {:error, {:missing_keys, missing}}
end

defmodule Pipeline.Stages.NormalizePayload do
  @moduledoc "Trims string fields and downcases identifiers in the payload map."

  @behaviour Pipeline.Stage

  @impl Pipeline.Stage
  def run(%{payload: payload} = context) when is_map(payload) do
    normalized = normalize_fields(payload)
    {:ok, Map.put(context, :payload, normalized)}
  end

  def run(_context), do: {:error, :payload_not_a_map}

  defp normalize_fields(payload) do
    Map.new(payload, fn
      {k, v} when is_binary(v) -> {k, String.trim(v)}
      pair -> pair
    end)
  end
end
```
