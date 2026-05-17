```elixir
# ── file: lib/onboarding/flow.ex ────────────────────────────────────────────

defmodule Onboarding.Flow do
  @moduledoc """
  Manages the multi-step onboarding flow for new user accounts.
  Defined in `lib/onboarding/flow.ex`.
  """

  alias Onboarding.{FlowStore, StepRegistry, TaskRunner, NotificationBus}

  @default_flow :standard

  @type user_id :: String.t()
  @type flow_name :: atom()
  @type step_id :: atom()

  @type flow_state :: %{
    id: String.t(),
    user_id: user_id(),
    flow: flow_name(),
    steps: [map()],
    current_step: step_id(),
    status: :in_progress | :completed | :abandoned,
    started_at: DateTime.t(),
    completed_at: DateTime.t() | nil
  }

  @doc """
  Start an onboarding flow for a new user.
  Returns `{:ok, flow_state}` with status `:in_progress`.
  """
  @spec start(user_id(), flow_name()) :: {:ok, flow_state()} | {:error, String.t()}
  def start(user_id, flow_name \\ @default_flow) do
    with {:ok, steps} <- StepRegistry.steps_for(flow_name) do
      now = DateTime.utc_now()

      state = %{
        id: generate_id(),
        user_id: user_id,
        flow: flow_name,
        steps: Enum.map(steps, &%{id: &1.id, status: :pending, completed_at: nil}),
        current_step: List.first(steps).id,
        status: :in_progress,
        started_at: now,
        completed_at: nil
      }

      with {:ok, saved} <- FlowStore.save(state) do
        NotificationBus.publish(:onboarding_started, %{user_id: user_id, flow: flow_name})
        {:ok, saved}
      end
    end
  end

  @doc "Move the flow to the next step after the current one is completed."
  @spec advance(user_id(), map()) :: {:ok, flow_state()} | {:error, String.t()}
  def advance(user_id, context \\ %{}) do
    with {:ok, state} <- FlowStore.fetch_active(user_id),
         :ok <- check_in_progress(state) do
      steps = state.steps
      current_idx = Enum.find_index(steps, &(&1.id == state.current_step))
      next_idx = current_idx + 1

      if next_idx >= length(steps) do
        finish(state)
      else
        next_step = Enum.at(steps, next_idx)
        updated = %{state | current_step: next_step.id}
        FlowStore.update(state.id, updated)
        TaskRunner.trigger_step(next_step.id, user_id, context)
        {:ok, updated}
      end
    end
  end

  @doc "Mark a specific step as completed with optional metadata."
  @spec complete_step(user_id(), step_id(), map()) ::
          {:ok, flow_state()} | {:error, String.t()}
  def complete_step(user_id, step_id, meta \\ %{}) do
    with {:ok, state} <- FlowStore.fetch_active(user_id) do
      updated_steps =
        Enum.map(state.steps, fn
          %{id: ^step_id} = step ->
            %{step | status: :completed, completed_at: DateTime.utc_now(), meta: meta}

          step ->
            step
        end)

      updated_state = %{state | steps: updated_steps}
      FlowStore.update(state.id, updated_state)
      advance(user_id)
    end
  end

  @doc "Return the current active step for a user's onboarding flow."
  @spec current_step(user_id()) :: {:ok, map()} | {:error, String.t()}
  def current_step(user_id) do
    with {:ok, state} <- FlowStore.fetch_active(user_id),
         {:ok, step_def} <- StepRegistry.fetch(state.current_step) do
      current = Enum.find(state.steps, &(&1.id == state.current_step))
      {:ok, Map.merge(step_def, current)}
    end
  end

  @doc "Return completion progress as a percentage."
  @spec progress(user_id()) :: {:ok, integer()} | {:error, String.t()}
  def progress(user_id) do
    with {:ok, state} <- FlowStore.fetch_active(user_id) do
      completed = Enum.count(state.steps, &(&1.status == :completed))
      pct = round(completed / length(state.steps) * 100)
      {:ok, pct}
    end
  end

  defp finish(state) do
    now = DateTime.utc_now()
    completed = %{state | status: :completed, completed_at: now}
    FlowStore.update(state.id, completed)
    NotificationBus.publish(:onboarding_completed, %{user_id: state.user_id})
    {:ok, completed}
  end

  defp check_in_progress(%{status: :in_progress}), do: :ok
  defp check_in_progress(%{status: s}), do: {:error, "Flow is not in progress (status: #{s})"}

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end


# ── file: lib/onboarding/flow_analytics.ex

defmodule Onboarding.Flow do
  @moduledoc """
  Analytics and funnel tracking for onboarding flow completions.
  Was intended to be `Onboarding.Flow.Analytics` but was accidentally given
  the same module name as the core flow manager.
  """

  alias Onboarding.FlowStore

  @doc "Return step-by-step drop-off rates for a given flow."
  @spec drop_off_rates(atom()) :: [%{step_id: atom(), drop_off_pct: float()}]
  def drop_off_rates(flow_name) do
    flows = FlowStore.all(flow: flow_name)
    total = max(length(flows), 1)

    all_step_ids =
      flows
      |> Enum.flat_map(& &1.steps)
      |> Enum.map(& &1.id)
      |> Enum.uniq()

    Enum.map(all_step_ids, fn step_id ->
      reached = Enum.count(flows, fn f -> Enum.any?(f.steps, &(&1.id == step_id)) end)
      drop_off = Float.round((1 - reached / total) * 100, 1)
      %{step_id: step_id, drop_off_pct: drop_off}
    end)
  end

  @doc "Return the median time-to-complete for a flow in hours."
  @spec median_completion_hours(atom()) :: float()
  def median_completion_hours(flow_name) do
    durations =
      FlowStore.all(flow: flow_name, status: :completed)
      |> Enum.map(fn f ->
        DateTime.diff(f.completed_at, f.started_at, :second) / 3600.0
      end)
      |> Enum.sort()

    case durations do
      [] ->
        0.0

      list ->
        mid = div(length(list), 2)
        if rem(length(list), 2) == 0 do
          (Enum.at(list, mid - 1) + Enum.at(list, mid)) / 2
        else
          Enum.at(list, mid)
        end
    end
  end

  @doc "Return counts of flows by status for an operations dashboard."
  @spec status_summary(atom()) :: map()
  def status_summary(flow_name) do
    FlowStore.all(flow: flow_name)
    |> Enum.group_by(& &1.status)
    |> Enum.map(fn {status, flows} -> {status, length(flows)} end)
    |> Map.new()
  end
end

```
