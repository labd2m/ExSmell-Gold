```elixir
defmodule Saga.Step do
  @moduledoc """
  A single saga step with a forward action and a compensating rollback action.
  Both are expressed as module/function/args triples to keep the step
  struct serializable and free of captured closures.
  """

  @enforce_keys [:name, :run_mfa, :compensate_mfa]
  defstruct [:name, :run_mfa, :compensate_mfa]

  @type mfa_spec :: {module(), atom(), list()}
  @type t :: %__MODULE__{name: atom(), run_mfa: mfa_spec(), compensate_mfa: mfa_spec()}

  @spec new(atom(), mfa_spec(), mfa_spec()) :: t()
  def new(name, run_mfa, compensate_mfa)
      when is_atom(name) and is_tuple(run_mfa) and is_tuple(compensate_mfa) do
    %__MODULE__{name: name, run_mfa: run_mfa, compensate_mfa: compensate_mfa}
  end
end

defmodule Saga.Execution do
  @moduledoc """
  Tracks the state of a saga execution: which steps have been completed,
  the accumulated context map, and the final outcome.
  """

  @enforce_keys [:id, :status, :completed_steps, :context]
  defstruct [:id, :status, :completed_steps, :context, :failed_step, :error]

  @type status :: :running | :completed | :compensating | :rolled_back | :compensation_failed
  @type t :: %__MODULE__{
          id: String.t(),
          status: status(),
          completed_steps: list(atom()),
          context: map(),
          failed_step: atom() | nil,
          error: term() | nil
        }

  @spec new(map()) :: t()
  def new(initial_context \\ %{}) when is_map(initial_context) do
    %__MODULE__{
      id: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false),
      status: :running,
      completed_steps: [],
      context: initial_context
    }
  end
end

defmodule Saga.Coordinator do
  @moduledoc """
  Runs a sequence of `Saga.Step` definitions against a shared context.
  On failure, executed steps are compensated in reverse order.
  Returns the final `Saga.Execution` with the full audit trail.
  """

  alias Saga.{Step, Execution}

  require Logger

  @spec run(list(Step.t()), map()) :: Execution.t()
  def run(steps, initial_context \\ %{}) when is_list(steps) and is_map(initial_context) do
    execution = Execution.new(initial_context)
    do_forward(steps, execution)
  end

  defp do_forward([], execution) do
    %{execution | status: :completed}
  end

  defp do_forward([%Step{} = step | rest], execution) do
    {mod, fun, extra_args} = step.run_mfa
    args = [execution.context | extra_args]

    case apply(mod, fun, args) do
      {:ok, updated_context} when is_map(updated_context) ->
        updated = %{execution |
          completed_steps: [step.name | execution.completed_steps],
          context: updated_context
        }
        do_forward(rest, updated)

      {:error, reason} ->
        Logger.warning("Saga step failed", saga_id: execution.id, step: step.name, reason: inspect(reason))
        failed = %{execution | status: :compensating, failed_step: step.name, error: reason}
        do_compensate(failed.completed_steps, steps, failed)
    end
  rescue
    err ->
      Logger.error("Saga step raised", saga_id: execution.id, error: Exception.message(err))
      failed = %{execution | status: :compensating, failed_step: :unknown, error: err}
      do_compensate(failed.completed_steps, steps, failed)
  end

  defp do_compensate([], _all_steps, execution) do
    %{execution | status: :rolled_back}
  end

  defp do_compensate([step_name | remaining], all_steps, execution) do
    step = Enum.find(all_steps, &(&1.name == step_name))
    {mod, fun, extra_args} = step.compensate_mfa
    args = [execution.context | extra_args]

    try do
      apply(mod, fun, args)
      do_compensate(remaining, all_steps, execution)
    rescue
      err ->
        Logger.error("Saga compensation failed", saga_id: execution.id, step: step_name, error: Exception.message(err))
        %{execution | status: :compensation_failed, error: err}
    end
  end
end
```
