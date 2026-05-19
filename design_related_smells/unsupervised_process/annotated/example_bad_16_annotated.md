# Annotated Example 16 — Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `Onboarding.StateMachine.start/2`
- **Affected function(s):** `start/2`
- **Short explanation:** Each new user's multi-step onboarding flow spawns a dedicated GenServer via `GenServer.start/3` outside any supervision tree. If this process crashes before the user completes onboarding, their progress is lost silently and they may be stuck in a broken state.

```elixir
defmodule Onboarding.StateMachine do
  use GenServer

  @moduledoc """
  Drives a new user through a multi-step onboarding workflow.
  Manages step transitions, captures per-step responses, enforces
  required steps, and triggers downstream hooks on completion.
  """

  @steps [
    :welcome,
    :profile_setup,
    :role_selection,
    :team_invitation,
    :preferences,
    :completed
  ]

  @required_steps [:profile_setup, :role_selection]

  defstruct [
    :flow_id,
    :user_id,
    :current_step,
    :completed_steps,
    :step_data,
    :status,
    :started_at,
    :completed_at
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because `GenServer.start/3` starts a user-onboarding
  # state machine process without placing it under a supervisor. In a SaaS product with
  # many sign-ups, there can be hundreds of concurrent onboarding processes. If one
  # crashes (e.g., due to invalid data in a step submission), the user's onboarding
  # progress is permanently lost. No supervisor restarts the process, so the user is
  # left in a partially initialized state with no way to resume.
  def start(user_id, opts \\ []) do
    flow_id = generate_flow_id()

    state = %__MODULE__{
      flow_id: flow_id,
      user_id: user_id,
      current_step: List.first(@steps),
      completed_steps: [],
      step_data: %{},
      status: :in_progress,
      started_at: DateTime.utc_now(),
      completed_at: nil
    }

    skip_steps = Keyword.get(opts, :skip_steps, [])
    initial_state = apply_skip(state, skip_steps)

    GenServer.start(__MODULE__, initial_state, name: via_name(user_id))
    {:ok, flow_id}
  end
  # VALIDATION: SMELL END

  @doc "Submits data for the current step and advances to the next."
  def submit_step(user_id, step, data) do
    GenServer.call(via_name(user_id), {:submit_step, step, data})
  end

  @doc "Skips an optional step."
  def skip_step(user_id, step) do
    GenServer.call(via_name(user_id), {:skip_step, step})
  end

  @doc "Returns the current onboarding state for a user."
  def get_state(user_id) do
    GenServer.call(via_name(user_id), :get_state)
  end

  @doc "Abandons the onboarding flow."
  def abandon(user_id) do
    GenServer.cast(via_name(user_id), :abandon)
  end

  ## Callbacks

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:submit_step, step, data}, _from, state) do
    cond do
      state.status != :in_progress ->
        {:reply, {:error, :flow_not_active}, state}

      state.current_step != step ->
        {:reply, {:error, {:wrong_step, state.current_step}}, state}

      true ->
        new_step_data = Map.put(state.step_data, step, data)
        new_completed = [step | state.completed_steps]

        next = next_step(step, state)

        new_state =
          if next == :completed do
            if all_required_complete?(new_completed) do
              %{state
                | current_step: :completed,
                  completed_steps: new_completed,
                  step_data: new_step_data,
                  status: :completed,
                  completed_at: DateTime.utc_now()}
            else
              missing = @required_steps -- new_completed
              {:reply, {:error, {:missing_required_steps, missing}}, state}
              state
            end
          else
            %{state
              | current_step: next,
                completed_steps: new_completed,
                step_data: new_step_data}
          end

        if new_state.status == :completed do
          trigger_completion_hooks(new_state)
        end

        {:reply, {:ok, new_state.current_step}, new_state}
    end
  end

  def handle_call({:skip_step, step}, _from, state) do
    if step in @required_steps do
      {:reply, {:error, :step_required}, state}
    else
      next = next_step(step, state)
      new_completed = [step | state.completed_steps]
      {:reply, {:ok, next}, %{state | current_step: next, completed_steps: new_completed}}
    end
  end

  def handle_call(:get_state, _from, state) do
    info = %{
      flow_id: state.flow_id,
      user_id: state.user_id,
      current_step: state.current_step,
      completed_steps: state.completed_steps,
      status: state.status,
      remaining_steps: remaining_steps(state),
      started_at: state.started_at,
      completed_at: state.completed_at
    }

    {:reply, info, state}
  end

  @impl true
  def handle_cast(:abandon, state) do
    {:noreply, %{state | status: :abandoned}}
  end

  defp next_step(current, _state) do
    idx = Enum.find_index(@steps, &(&1 == current))
    Enum.at(@steps, idx + 1, :completed)
  end

  defp remaining_steps(state) do
    idx = Enum.find_index(@steps, &(&1 == state.current_step)) || 0
    Enum.drop(@steps, idx + 1)
  end

  defp all_required_complete?(completed_steps) do
    Enum.all?(@required_steps, &(&1 in completed_steps))
  end

  defp apply_skip(state, []), do: state

  defp apply_skip(state, skip_steps) do
    optional = skip_steps -- @required_steps

    Enum.reduce(optional, state, fn step, acc ->
      if step == acc.current_step do
        next = next_step(step, acc)
        %{acc | current_step: next, completed_steps: [step | acc.completed_steps]}
      else
        acc
      end
    end)
  end

  defp trigger_completion_hooks(_state), do: :ok

  defp via_name(user_id) do
    {:via, Registry, {Onboarding.FlowRegistry, user_id}}
  end

  defp generate_flow_id do
    :crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false)
  end
end
```
