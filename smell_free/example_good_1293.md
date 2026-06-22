```elixir
defmodule Sagas.Orchestrator do
  @moduledoc """
  Generic saga orchestrator that executes ordered steps and compensates on failure.

  Steps are modules implementing `Sagas.Step`. The orchestrator runs steps
  sequentially, building a compensation stack. On any failure it runs
  compensation in reverse order before returning the error.
  """

  alias Sagas.{Step, SagaContext, SagaResult}

  @doc """
  Runs a saga defined by an ordered list of step modules against an initial context.

  Returns `{:ok, final_context}` if all steps succeed, or
  `{:error, reason, compensation_errors}` after compensating completed steps.
  """
  @spec run(SagaContext.t(), [module()]) ::
          {:ok, SagaContext.t()} | {:error, String.t(), [String.t()]}
  def run(%SagaContext{} = context, steps) when is_list(steps) and steps != [] do
    execute(context, steps, [])
  end

  def run(_, _), do: {:error, "at least one step is required", []}

  defp execute(context, [], _completed_steps) do
    {:ok, context}
  end

  defp execute(context, [step | remaining], completed) do
    case Step.execute(step, context) do
      {:ok, updated_context} ->
        execute(updated_context, remaining, [{step, context} | completed])

      {:error, reason} ->
        comp_errors = compensate_all(completed)
        {:error, reason, comp_errors}
    end
  end

  defp compensate_all(completed_steps) do
    completed_steps
    |> Enum.reduce([], fn {step, ctx_before}, errors ->
      case Step.compensate(step, ctx_before) do
        :ok -> errors
        {:error, reason} -> ["#{inspect(step)}: #{reason}" | errors]
      end
    end)
  end
end

defmodule Sagas.Step do
  @moduledoc "Behaviour contract for a single reversible saga step."

  alias Sagas.SagaContext

  @callback execute(SagaContext.t()) :: {:ok, SagaContext.t()} | {:error, String.t()}
  @callback compensate(SagaContext.t()) :: :ok | {:error, String.t()}

  @spec execute(module(), SagaContext.t()) :: {:ok, SagaContext.t()} | {:error, String.t()}
  def execute(step_module, context), do: step_module.execute(context)

  @spec compensate(module(), SagaContext.t()) :: :ok | {:error, String.t()}
  def compensate(step_module, context), do: step_module.compensate(context)
end

defmodule Sagas.SagaContext do
  @moduledoc """
  Carries accumulated state and artifacts through a saga execution.

  Steps read from and write to the context map rather than relying on
  external mutable state, keeping the saga execution portable and testable.
  """

  @enforce_keys [:saga_id, :initiated_by]
  defstruct [:saga_id, :initiated_by, data: %{}, metadata: %{}]

  @type t :: %__MODULE__{
          saga_id: String.t(),
          initiated_by: String.t(),
          data: map(),
          metadata: map()
        }

  @spec new(String.t(), String.t(), map()) :: t()
  def new(saga_id, initiated_by, initial_data \\ %{})
      when is_binary(saga_id) and is_binary(initiated_by) do
    %__MODULE__{saga_id: saga_id, initiated_by: initiated_by, data: initial_data}
  end

  @spec put(t(), atom() | String.t(), term()) :: t()
  def put(%__MODULE__{data: data} = ctx, key, value) do
    %{ctx | data: Map.put(data, key, value)}
  end

  @spec fetch(t(), atom() | String.t()) :: {:ok, term()} | :error
  def fetch(%__MODULE__{data: data}, key), do: Map.fetch(data, key)

  @spec get(t(), atom() | String.t(), term()) :: term()
  def get(%__MODULE__{data: data}, key, default \\ nil), do: Map.get(data, key, default)
end

defmodule Sagas.SagaResult do
  @moduledoc "Typed result from a completed or failed saga run."

  @enforce_keys [:saga_id, :status]
  defstruct [:saga_id, :status, :context, :error, compensation_errors: []]

  @type t :: %__MODULE__{}

  @spec succeeded(Sagas.SagaContext.t()) :: t()
  def succeeded(%{saga_id: id} = ctx) do
    %__MODULE__{saga_id: id, status: :succeeded, context: ctx}
  end

  @spec failed(String.t(), String.t(), [String.t()]) :: t()
  def failed(saga_id, error, comp_errors \\ []) do
    %__MODULE__{saga_id: saga_id, status: :failed, error: error, compensation_errors: comp_errors}
  end
end
```
