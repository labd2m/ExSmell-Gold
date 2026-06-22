```elixir
defmodule Etl.Pipeline do
  @moduledoc """
  Composable data pipeline that runs records through a sequence of transform stages.

  Each stage is a module implementing the `Etl.Stage` behaviour.
  Errors are accumulated per-record and do not halt processing of remaining records.
  """

  alias Etl.{Stage, PipelineResult}

  @type record :: map()
  @type stage_module :: module()

  @type run_result :: %{
          succeeded: [PipelineResult.t()],
          failed: [PipelineResult.t()]
        }

  @doc """
  Builds a pipeline from an ordered list of stage modules.
  """
  @spec new([stage_module()]) :: {:ok, [stage_module()]} | {:error, String.t()}
  def new(stages) when is_list(stages) and stages != [] do
    case Enum.find(stages, fn m -> not implements_stage?(m) end) do
      nil -> {:ok, stages}
      bad -> {:error, "#{inspect(bad)} does not implement Etl.Stage"}
    end
  end

  def new(_), do: {:error, "pipeline requires at least one stage"}

  @doc """
  Processes a list of records through all pipeline stages.

  Returns a map with `:succeeded` and `:failed` record results.
  """
  @spec run([record()], [stage_module()]) :: run_result()
  def run(records, stages) when is_list(records) and is_list(stages) do
    results = Enum.map(records, fn record ->
      execute_stages(record, stages)
    end)

    Enum.group_by(results, fn
      %PipelineResult{status: :ok} -> :succeeded
      %PipelineResult{status: :error} -> :failed
    end)
    |> Map.merge(%{succeeded: [], failed: []}, fn _k, new, default -> new ++ default end)
  end

  defp execute_stages(record, stages) do
    Enum.reduce_while(stages, {:ok, record}, fn stage, {:ok, current} ->
      case Stage.transform(stage, current) do
        {:ok, transformed} -> {:cont, {:ok, transformed}}
        {:error, reason} -> {:halt, {:error, reason, stage}}
      end
    end)
    |> to_result(record)
  end

  defp to_result({:ok, transformed}, _original) do
    %PipelineResult{status: :ok, output: transformed}
  end

  defp to_result({:error, reason, stage}, original) do
    %PipelineResult{status: :error, input: original, error: reason, failed_stage: stage}
  end

  defp implements_stage?(module) do
    :erlang.function_exported(module, :transform, 2)
  end
end

defmodule Etl.Stage do
  @moduledoc "Behaviour contract for a single transformation stage."

  @callback transform(map()) :: {:ok, map()} | {:error, String.t()}

  @spec transform(module(), map()) :: {:ok, map()} | {:error, String.t()}
  def transform(module, record), do: module.transform(record)
end

defmodule Etl.PipelineResult do
  @moduledoc false

  defstruct [:status, :output, :input, :error, :failed_stage]

  @type t :: %__MODULE__{
          status: :ok | :error,
          output: map() | nil,
          input: map() | nil,
          error: String.t() | nil,
          failed_stage: module() | nil
        }
end

defmodule Etl.Stages.NormalizeKeys do
  @moduledoc "Stage that converts all map string keys to atom keys using a fixed allowlist."

  @behaviour Etl.Stage

  @allowed_keys ~w[id name email created_at]

  @impl Etl.Stage
  def transform(record) when is_map(record) do
    normalized =
      Map.new(record, fn {k, v} ->
        atom_key = if is_binary(k), do: String.to_existing_atom(k), else: k
        {atom_key, v}
      end)

    {:ok, normalized}
  rescue
    ArgumentError -> {:error, "record contains unexpected keys"}
  end

  def transform(_), do: {:error, "expected a map"}
end
```
