```elixir
defmodule Onboarding.WorkflowEngine do
  @moduledoc """
  Drives a user through a sequential onboarding workflow composed of
  discrete, independently completable steps. Each step is validated
  before advancing, and the overall progress is persisted per-user.
  """

  alias Onboarding.{Repo, WorkflowState, StepValidator}

  @ordered_steps [
    :verify_email,
    :complete_profile,
    :connect_integration,
    :invite_teammates,
    :take_product_tour
  ]

  @type step :: atom()

  @type progress :: %{
          user_id: String.t(),
          completed_steps: [step()],
          current_step: step() | :complete,
          percent_complete: non_neg_integer()
        }

  @spec get_progress(String.t()) :: {:ok, progress()} | {:error, :not_found}
  def get_progress(user_id) when is_binary(user_id) do
    case Repo.get_by(WorkflowState, user_id: user_id) do
      nil -> {:error, :not_found}
      state -> {:ok, build_progress(state)}
    end
  end

  @spec initialize(String.t()) :: {:ok, progress()} | {:error, Ecto.Changeset.t()}
  def initialize(user_id) when is_binary(user_id) do
    %WorkflowState{}
    |> WorkflowState.creation_changeset(%{user_id: user_id, completed_steps: []})
    |> Repo.insert()
    |> case do
      {:ok, state} -> {:ok, build_progress(state)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @spec complete_step(String.t(), step()) ::
          {:ok, progress()} | {:error, :not_found | :invalid_step | :already_completed | :prerequisites_incomplete | Ecto.Changeset.t()}
  def complete_step(user_id, step) when is_binary(user_id) and is_atom(step) do
    with {:ok, state} <- fetch_state(user_id),
         :ok <- validate_step(step),
         :ok <- check_not_already_completed(state, step),
         :ok <- check_prerequisites(state, step),
         :ok <- StepValidator.validate(user_id, step),
         {:ok, updated} <- mark_complete(state, step) do
      {:ok, build_progress(updated)}
    end
  end

  @spec skip_optional_step(String.t(), step()) ::
          {:ok, progress()} | {:error, :not_found | :not_skippable}
  def skip_optional_step(user_id, step) when is_binary(user_id) do
    optional_steps = [:invite_teammates, :connect_integration]

    if step in optional_steps do
      complete_step(user_id, step)
    else
      {:error, :not_skippable}
    end
  end

  @spec fetch_state(String.t()) :: {:ok, WorkflowState.t()} | {:error, :not_found}
  defp fetch_state(user_id) do
    case Repo.get_by(WorkflowState, user_id: user_id) do
      nil -> {:error, :not_found}
      state -> {:ok, state}
    end
  end

  @spec validate_step(step()) :: :ok | {:error, :invalid_step}
  defp validate_step(step) do
    if step in @ordered_steps, do: :ok, else: {:error, :invalid_step}
  end

  @spec check_not_already_completed(WorkflowState.t(), step()) ::
          :ok | {:error, :already_completed}
  defp check_not_already_completed(state, step) do
    if step in state.completed_steps, do: {:error, :already_completed}, else: :ok
  end

  @spec check_prerequisites(WorkflowState.t(), step()) ::
          :ok | {:error, :prerequisites_incomplete}
  defp check_prerequisites(state, step) do
    step_index = Enum.find_index(@ordered_steps, &(&1 == step))
    prerequisites = Enum.take(@ordered_steps, step_index)
    all_done = Enum.all?(prerequisites, &(&1 in state.completed_steps))
    if all_done, do: :ok, else: {:error, :prerequisites_incomplete}
  end

  @spec mark_complete(WorkflowState.t(), step()) ::
          {:ok, WorkflowState.t()} | {:error, Ecto.Changeset.t()}
  defp mark_complete(state, step) do
    updated_steps = Enum.uniq(state.completed_steps ++ [step])
    state |> WorkflowState.update_changeset(%{completed_steps: updated_steps}) |> Repo.update()
  end

  @spec build_progress(WorkflowState.t()) :: progress()
  defp build_progress(state) do
    completed = state.completed_steps
    total = length(@ordered_steps)
    percent = round(length(completed) / total * 100)
    current = Enum.find(@ordered_steps, :complete, &(&1 not in completed))

    %{
      user_id: state.user_id,
      completed_steps: completed,
      current_step: current,
      percent_complete: percent
    }
  end
end
```
