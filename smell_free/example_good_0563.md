```elixir
defmodule Approval.Stage do
  @moduledoc false

  @type strategy :: :any | :all

  @type t :: %__MODULE__{
          name: atom(),
          approvers: [String.t()],
          strategy: strategy()
        }

  defstruct [:name, :approvers, strategy: :any]
end

defmodule Approval.Request do
  @moduledoc false

  @type stage_state :: %{
          stage: atom(),
          approved_by: [String.t()],
          rejected_by: [String.t()],
          status: :pending | :approved | :rejected
        }

  @type t :: %__MODULE__{
          id: String.t(),
          subject_id: String.t(),
          current_stage_index: non_neg_integer(),
          stage_states: [stage_state()],
          status: :pending | :approved | :rejected | :cancelled
        }

  defstruct [:id, :subject_id, :current_stage_index, :stage_states, status: :pending]
end

defmodule Approval.Workflow do
  @moduledoc """
  Manages a multi-stage approval request through an ordered list of stages.

  Each stage specifies a list of approver IDs and a strategy: `:any`
  advances when one approver acts, `:all` requires every approver to act.
  A rejection at any stage immediately rejects the entire request. Once all
  stages pass, the request moves to `:approved`. All state transitions are
  returned as updated `Request` structs rather than performed in place.
  """

  alias Approval.{Request, Stage}

  @spec start(String.t(), String.t(), [Stage.t()]) :: {:ok, Request.t()} | {:error, :no_stages}
  def start(request_id, subject_id, stages) when is_list(stages) and stages != [] do
    stage_states = Enum.map(stages, fn %Stage{name: name} ->
      %{stage: name, approved_by: [], rejected_by: [], status: :pending}
    end)

    {:ok, %Request{id: request_id, subject_id: subject_id,
                   current_stage_index: 0, stage_states: stage_states}}
  end

  def start(_id, _subject, []), do: {:error, :no_stages}

  @spec approve(Request.t(), String.t(), [Stage.t()]) ::
          {:ok, Request.t()} | {:error, :not_approver | :already_acted | :not_pending}
  def approve(%Request{status: :pending} = request, approver_id, stages) do
    stage = current_stage(stages, request.current_stage_index)
    stage_state = Enum.at(request.stage_states, request.current_stage_index)

    with :ok <- validate_approver(approver_id, stage),
         :ok <- validate_not_acted(approver_id, stage_state) do
      updated_state = %{stage_state | approved_by: [approver_id | stage_state.approved_by]}
      new_stage_state = evaluate_stage(updated_state, stage)
      advance(request, new_stage_state, stages)
    end
  end

  def approve(%Request{}, _approver, _stages), do: {:error, :not_pending}

  @spec reject(Request.t(), String.t(), [Stage.t()]) ::
          {:ok, Request.t()} | {:error, :not_approver | :already_acted | :not_pending}
  def reject(%Request{status: :pending} = request, approver_id, stages) do
    stage = current_stage(stages, request.current_stage_index)
    stage_state = Enum.at(request.stage_states, request.current_stage_index)

    with :ok <- validate_approver(approver_id, stage),
         :ok <- validate_not_acted(approver_id, stage_state) do
      updated_state = %{stage_state | rejected_by: [approver_id | stage_state.rejected_by], status: :rejected}
      updated_states = List.replace_at(request.stage_states, request.current_stage_index, updated_state)
      {:ok, %{request | stage_states: updated_states, status: :rejected}}
    end
  end

  def reject(%Request{}, _approver, _stages), do: {:error, :not_pending}

  defp advance(request, new_stage_state, stages) do
    updated_states = List.replace_at(request.stage_states, request.current_stage_index, new_stage_state)
    updated = %{request | stage_states: updated_states}

    case new_stage_state.status do
      :pending ->
        {:ok, updated}

      :approved ->
        next_idx = request.current_stage_index + 1

        if next_idx >= length(stages) do
          {:ok, %{updated | status: :approved}}
        else
          {:ok, %{updated | current_stage_index: next_idx}}
        end
    end
  end

  defp evaluate_stage(%{approved_by: approved} = state, %Stage{strategy: :any}) when approved != [] do
    %{state | status: :approved}
  end

  defp evaluate_stage(%{approved_by: approved} = state, %Stage{strategy: :all, approvers: all}) do
    if Enum.all?(all, &(&1 in approved)), do: %{state | status: :approved}, else: state
  end

  defp evaluate_stage(state, _stage), do: state

  defp current_stage(stages, idx), do: Enum.at(stages, idx)

  defp validate_approver(approver_id, %Stage{approvers: approvers}) do
    if approver_id in approvers, do: :ok, else: {:error, :not_approver}
  end

  defp validate_not_acted(approver_id, %{approved_by: approved, rejected_by: rejected}) do
    if approver_id in approved or approver_id in rejected, do: {:error, :already_acted}, else: :ok
  end
end
```
