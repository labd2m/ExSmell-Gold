```elixir
defmodule Pipelines.EtlRunner do
  @moduledoc """
  Executes configurable ETL pipelines composed of named extract,
  transform, and load stages.

  Each pipeline is defined as a struct describing the source adapter,
  a list of transformation steps, and a destination adapter. The runner
  coordinates stage execution and accumulates per-stage telemetry into
  a run report returned to the caller.
  """

  alias Pipelines.Pipeline
  alias Pipelines.RunReport
  alias Pipelines.StageResult

  @type row :: map()
  @type stage_name :: atom()
  @type run_result ::
          {:ok, RunReport.t()}
          | {:error, :extract_failed, term()}
          | {:error, :load_failed, term()}
          | {:error, :transform_failed, stage_name(), term()}

  @doc """
  Executes the given pipeline end-to-end.

  Returns `{:ok, report}` on full success, or a structured error
  identifying which stage failed and why.
  """
  @spec run(Pipeline.t()) :: run_result()
  def run(%Pipeline{} = pipeline) do
    started_at = DateTime.utc_now()

    with {:ok, rows, extract_meta} <- extract(pipeline),
         {:ok, transformed, transform_meta} <- transform(rows, pipeline.transforms),
         {:ok, load_meta} <- load(transformed, pipeline) do
      report = %RunReport{
        pipeline_id: pipeline.id,
        row_count: length(transformed),
        started_at: started_at,
        completed_at: DateTime.utc_now(),
        stage_results: extract_meta ++ transform_meta ++ [load_meta]
      }

      {:ok, report}
    end
  end

  @spec extract(Pipeline.t()) ::
          {:ok, [row()], [StageResult.t()]} | {:error, :extract_failed, term()}
  defp extract(%Pipeline{source: source_adapter, source_opts: opts}) do
    case source_adapter.fetch(opts) do
      {:ok, rows} when is_list(rows) ->
        result = %StageResult{stage: :extract, row_count: length(rows), status: :ok}
        {:ok, rows, [result]}

      {:error, reason} ->
        {:error, :extract_failed, reason}
    end
  end

  @spec transform([row()], [{stage_name(), module(), keyword()}]) ::
          {:ok, [row()], [StageResult.t()]}
          | {:error, :transform_failed, stage_name(), term()}
  defp transform(rows, transforms) do
    Enum.reduce_while(transforms, {:ok, rows, []}, fn {name, module, opts}, {:ok, acc_rows, acc_results} ->
      case module.apply(acc_rows, opts) do
        {:ok, updated_rows} ->
          result = %StageResult{stage: name, row_count: length(updated_rows), status: :ok}
          {:cont, {:ok, updated_rows, acc_results ++ [result]}}

        {:error, reason} ->
          {:halt, {:error, :transform_failed, name, reason}}
      end
    end)
  end

  @spec load([row()], Pipeline.t()) ::
          {:ok, StageResult.t()} | {:error, :load_failed, term()}
  defp load(rows, %Pipeline{destination: dest_adapter, destination_opts: opts}) do
    case dest_adapter.write(rows, opts) do
      :ok ->
        result = %StageResult{stage: :load, row_count: length(rows), status: :ok}
        {:ok, result}

      {:error, reason} ->
        {:error, :load_failed, reason}
    end
  end
end

defmodule Pipelines.Pipeline do
  @moduledoc """
  Struct describing the configuration of a single ETL pipeline.
  """

  @enforce_keys [:id, :source, :source_opts, :destination, :destination_opts, :transforms]

  defstruct [:id, :source, :source_opts, :destination, :destination_opts, transforms: []]

  @type transform_step :: {atom(), module(), keyword()}

  @type t :: %__MODULE__{
          id: String.t(),
          source: module(),
          source_opts: keyword(),
          destination: module(),
          destination_opts: keyword(),
          transforms: [transform_step()]
        }
end
```
