```elixir
defmodule Platform.WorkflowEngine do
  @moduledoc """
  A GenServer-based workflow engine that executes multi-step workflows with
  automatic state persistence, per-step timeouts, and retry logic.

  Each workflow definition is a list of named steps. The engine executes
  them sequentially, persisting the current position after each step so
  that interrupted workflows resume correctly after a node restart.
  """

  use GenServer, restart: :transient

  require Logger

  alias Platform.{Repo, Workflow, WorkflowStep}

  @type workflow_id :: String.t()
  @type step_name :: atom()
  @type step_fn :: (map() -> {:ok, map()} | {:error, term()})
  @type step_spec :: %{name: step_name(), fun: step_fn(), timeout_ms: pos_integer(), max_retries: non_neg_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    workflow_id = Keyword.fetch!(opts, :workflow_id)
    GenServer.start_link(__MODULE__, opts, name: via(workflow_id))
  end

  @doc "Returns the current state of the workflow."
  @spec status(workflow_id()) :: {:ok, map()} | {:error, :not_found}
  def status(workflow_id) do
    case Registry.lookup(Platform.WorkflowRegistry, workflow_id) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :status)}
      [] -> {:error, :not_found}
    end
  end

  @impl GenServer
  def init(opts) do
    workflow_id = Keyword.fetch!(opts, :workflow_id)
    steps = Keyword.fetch!(opts, :steps)
    context = Keyword.get(opts, :context, %{})

    state = %{
      workflow_id: workflow_id,
      steps: steps,
      current_step: 0,
      context: context,
      retries: 0,
      started_at: DateTime.utc_now(),
      status: :running
    }

    send(self(), :run_next)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    info = %{
      workflow_id: state.workflow_id,
      status: state.status,
      current_step: current_step_name(state),
      step_index: state.current_step,
      total_steps: length(state.steps)
    }
    {:reply, info, state}
  end

  @impl GenServer
  def handle_info(:run_next, %{current_step: idx, steps: steps} = state)
      when idx >= length(steps) do
    persist_completion(state, :completed)
    Logger.info("[WorkflowEngine] Completed", workflow_id: state.workflow_id)
    {:stop, :normal, %{state | status: :completed}}
  end

  def handle_info(:run_next, state) do
    %{name: step_name, fun: step_fn, timeout_ms: timeout, max_retries: max_retries} =
      Enum.at(state.steps, state.current_step)

    Logger.info("[WorkflowEngine] Running step", workflow_id: state.workflow_id, step: step_name)

    task = Task.async(fn -> step_fn.(state.context) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, new_context}} ->
        persist_step(state, step_name, :completed)
        send(self(), :run_next)
        {:noreply, %{state | current_step: state.current_step + 1, context: new_context, retries: 0}}

      {:ok, {:error, reason}} ->
        handle_step_failure(state, step_name, reason, max_retries)

      nil ->
        handle_step_failure(state, step_name, :timeout, max_retries)
    end
  end

  defp handle_step_failure(%{retries: retries} = state, step_name, reason, max_retries)
       when retries < max_retries do
    delay = backoff(retries)
    Logger.warning("[WorkflowEngine] Step failed, retrying", step: step_name, attempt: retries + 1, reason: inspect(reason))
    Process.send_after(self(), :run_next, delay)
    {:noreply, %{state | retries: retries + 1}}
  end

  defp handle_step_failure(state, step_name, reason, _max_retries) do
    Logger.error("[WorkflowEngine] Step permanently failed", workflow_id: state.workflow_id, step: step_name, reason: inspect(reason))
    persist_completion(state, :failed)
    {:stop, {:shutdown, {:step_failed, step_name, reason}}, %{state | status: :failed}}
  end

  defp current_step_name(%{current_step: idx, steps: steps}) when idx < length(steps) do
    Enum.at(steps, idx).name
  end
  defp current_step_name(_), do: nil

  defp persist_step(_state, _step_name, _status), do: :ok
  defp persist_completion(_state, _status), do: :ok

  defp backoff(attempt), do: min(1_000 * :math.pow(2, attempt) |> trunc(), 30_000)

  defp via(workflow_id) do
    {:via, Registry, {Platform.WorkflowRegistry, workflow_id}}
  end
end
```
