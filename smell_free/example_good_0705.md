# File: `example_good_705.md`

```elixir
defmodule Workflow.TimedEscalation do
  @moduledoc """
  GenServer that monitors pending tasks against their deadlines and
  triggers escalation notifications through a configurable handler
  when tasks are not resolved within their SLA window.

  Escalation levels are configurable: a task can be escalated to tier-1
  at 50% of its window, tier-2 at 75%, and marked critical at 100%.
  Each escalation fires once per task per level.
  """

  use GenServer

  require Logger

  @default_poll_interval_ms 60_000

  @type task_id :: String.t()
  @type escalation_level :: :tier1 | :tier2 | :critical

  @type tracked_task :: %{
          id: task_id(),
          deadline: DateTime.t(),
          registered_at: DateTime.t(),
          escalations_fired: MapSet.t()
        }

  @type opts :: [
          handler: module(),
          poll_interval_ms: pos_integer(),
          tier1_threshold: float(),
          tier2_threshold: float()
        ]

  @doc false
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a task to be monitored against its deadline.

  Returns `:ok` or `{:error, :already_tracked}`.
  """
  @spec track(task_id(), DateTime.t()) :: :ok | {:error, :already_tracked}
  def track(task_id, %DateTime{} = deadline) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:track, task_id, deadline})
  end

  @doc """
  Removes a task from escalation monitoring (e.g. after resolution).
  """
  @spec resolve(task_id()) :: :ok
  def resolve(task_id) when is_binary(task_id) do
    GenServer.cast(__MODULE__, {:resolve, task_id})
  end

  @doc """
  Returns all currently monitored tasks.
  """
  @spec tracked_tasks() :: [tracked_task()]
  def tracked_tasks do
    GenServer.call(__MODULE__, :tracked_tasks)
  end

  @impl GenServer
  def init(opts) do
    handler = Keyword.fetch!(opts, :handler)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    tier1 = Keyword.get(opts, :tier1_threshold, 0.5)
    tier2 = Keyword.get(opts, :tier2_threshold, 0.75)

    schedule_poll(poll_interval_ms)

    {:ok, %{tasks: %{}, handler: handler, poll_interval_ms: poll_interval_ms,
            tier1_threshold: tier1, tier2_threshold: tier2}}
  end

  @impl GenServer
  def handle_call({:track, task_id, deadline}, _from, state) do
    if Map.has_key?(state.tasks, task_id) do
      {:reply, {:error, :already_tracked}, state}
    else
      task = %{id: task_id, deadline: deadline, registered_at: DateTime.utc_now(),
               escalations_fired: MapSet.new()}
      {:reply, :ok, put_in(state, [:tasks, task_id], task)}
    end
  end

  @impl GenServer
  def handle_call(:tracked_tasks, _from, state) do
    {:reply, Map.values(state.tasks), state}
  end

  @impl GenServer
  def handle_cast({:resolve, task_id}, state) do
    {:noreply, update_in(state, [:tasks], &Map.delete(&1, task_id))}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    now = DateTime.utc_now()
    new_tasks = Map.new(state.tasks, fn {id, task} ->
      updated = maybe_escalate(task, now, state)
      {id, updated}
    end)

    schedule_poll(state.poll_interval_ms)
    {:noreply, %{state | tasks: new_tasks}}
  end

  defp maybe_escalate(task, now, state) do
    total_seconds = DateTime.diff(task.deadline, task.registered_at)
    elapsed_seconds = DateTime.diff(now, task.registered_at)
    progress = if total_seconds > 0, do: elapsed_seconds / total_seconds, else: 1.0

    task
    |> check_level(:tier1, state.tier1_threshold, progress, state.handler)
    |> check_level(:tier2, state.tier2_threshold, progress, state.handler)
    |> check_level(:critical, 1.0, progress, state.handler)
  end

  defp check_level(task, level, threshold, progress, handler) do
    should_fire = progress >= threshold and not MapSet.member?(task.escalations_fired, level)

    if should_fire do
      fire_escalation(task, level, handler)
      %{task | escalations_fired: MapSet.put(task.escalations_fired, level)}
    else
      task
    end
  end

  defp fire_escalation(task, level, handler) do
    Logger.warning("Escalating task #{task.id} to #{level}")

    case handler.escalate(task.id, level, task.deadline) do
      :ok -> :ok
      {:error, reason} ->
        Logger.error("Escalation handler failed for #{task.id}: #{inspect(reason)}")
    end
  rescue
    e -> Logger.error("Escalation handler raised: #{Exception.message(e)}")
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
```
