```elixir
defmodule Forms.MultiStepState do
  @moduledoc """
  Manages the server-side state of a multi-step form session. Each step
  has an independent schema for validation; partial data is accumulated
  across steps and only committed to the database on final submission.
  """

  alias Forms.{StepValidator, SessionStore}

  @type step :: atom()
  @type form_id :: String.t()

  @type form_state :: %{
          form_id: form_id(),
          current_step: step(),
          completed_steps: [step()],
          data: map(),
          errors: map()
        }

  @ordered_steps [:personal_info, :contact_details, :preferences, :review]

  @spec new(form_id()) :: form_state()
  def new(form_id) when is_binary(form_id) do
    state = %{
      form_id: form_id,
      current_step: List.first(@ordered_steps),
      completed_steps: [],
      data: %{},
      errors: %{}
    }

    SessionStore.put(form_id, state)
    state
  end

  @spec load(form_id()) :: {:ok, form_state()} | {:error, :not_found}
  def load(form_id) when is_binary(form_id) do
    SessionStore.get(form_id)
  end

  @spec submit_step(form_id(), step(), map()) ::
          {:ok, form_state()} | {:error, :wrong_step | :validation_failed | :not_found}
  def submit_step(form_id, step, params) when is_binary(form_id) and is_atom(step) do
    with {:ok, state} <- load(form_id),
         :ok <- check_current_step(state, step),
         :ok <- validate_step(step, params) do
      updated = advance(state, step, params)
      SessionStore.put(form_id, updated)
      {:ok, updated}
    else
      {:error, {:validation_errors, errors}} ->
        with {:ok, state} <- load(form_id) do
          errored = %{state | errors: Map.put(state.errors, step, errors)}
          SessionStore.put(form_id, errored)
          {:error, :validation_failed}
        end

      other ->
        other
    end
  end

  @spec go_back(form_id()) :: {:ok, form_state()} | {:error, :not_found | :already_at_start}
  def go_back(form_id) when is_binary(form_id) do
    with {:ok, state} <- load(form_id) do
      current_index = Enum.find_index(@ordered_steps, &(&1 == state.current_step))

      if current_index == 0 do
        {:error, :already_at_start}
      else
        prev_step = Enum.at(@ordered_steps, current_index - 1)
        updated = %{state | current_step: prev_step,
                            completed_steps: List.delete(state.completed_steps, state.current_step)}
        SessionStore.put(form_id, updated)
        {:ok, updated}
      end
    end
  end

  @spec complete?(form_state()) :: boolean()
  def complete?(%{completed_steps: completed}) do
    Enum.all?(@ordered_steps, &(&1 in completed))
  end

  @spec collected_data(form_id()) :: {:ok, map()} | {:error, :not_found | :incomplete}
  def collected_data(form_id) when is_binary(form_id) do
    with {:ok, state} <- load(form_id) do
      if complete?(state) do
        {:ok, state.data}
      else
        {:error, :incomplete}
      end
    end
  end

  @spec check_current_step(form_state(), step()) :: :ok | {:error, :wrong_step}
  defp check_current_step(%{current_step: current}, step) do
    if current == step, do: :ok, else: {:error, :wrong_step}
  end

  @spec validate_step(step(), map()) :: :ok | {:error, {:validation_errors, map()}}
  defp validate_step(step, params) do
    case StepValidator.validate(step, params) do
      :ok -> :ok
      {:error, errors} -> {:error, {:validation_errors, errors}}
    end
  end

  @spec advance(form_state(), step(), map()) :: form_state()
  defp advance(state, step, params) do
    next_step = next_step_after(step)
    merged_data = Map.merge(state.data, params)

    %{state |
      current_step: next_step || step,
      completed_steps: Enum.uniq(state.completed_steps ++ [step]),
      data: merged_data,
      errors: Map.delete(state.errors, step)}
  end

  @spec next_step_after(step()) :: step() | nil
  defp next_step_after(step) do
    index = Enum.find_index(@ordered_steps, &(&1 == step))
    Enum.at(@ordered_steps, index + 1)
  end
end
```
