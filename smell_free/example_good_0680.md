```elixir
defmodule Workflow.Step do
  @moduledoc false

  @type t :: %__MODULE__{
          name: atom(),
          run: (map() -> {:ok, map()} | {:error, term()}),
          on_error: :halt | :skip,
          timeout_ms: pos_integer()
        }

  defstruct [:name, :run, on_error: :halt, timeout_ms: 5_000]
end

defmodule Workflow.ExecutionResult do
  @moduledoc false

  @type t :: %__MODULE__{
          status: :completed | :failed | :partial,
          context: map(),
          completed_steps: [atom()],
          skipped_steps: [atom()],
          failed_step: atom() | nil,
          failure_reason: term() | nil,
          duration_ms: non_neg_integer()
        }

  defstruct [:status, :context, :completed_steps, :skipped_steps,
             :failed_step, :failure_reason, :duration_ms]
end

defmodule Workflow.Registry do
  @moduledoc """
  A named registry for composable multi-step workflows.

  Workflows are registered as ordered lists of `Step` structs and can
  be executed by name. Each step receives and returns a shared context
  map. Steps with `on_error: :halt` abort the workflow on failure;
  steps with `on_error: :skip` record the error and continue. All
  results are gathered into a typed `ExecutionResult`.
  """

  use GenServer

  alias Workflow.{ExecutionResult, Step}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(atom(), [Step.t()]) :: :ok | {:error, :duplicate}
  def register(name, steps) when is_atom(name) and is_list(steps) do
    GenServer.call(__MODULE__, {:register, name, steps})
  end

  @spec execute(atom(), map()) :: {:ok, ExecutionResult.t()} | {:error, :not_found}
  def execute(name, initial_context \\ %{}) when is_atom(name) and is_map(initial_context) do
    GenServer.call(__MODULE__, {:execute, name, initial_context})
  end

  @spec list() :: [atom()]
  def list, do: GenServer.call(__MODULE__, :list)

  @impl GenServer
  def init(_opts), do: {:ok, %{workflows: %{}}}

  @impl GenServer
  def handle_call({:register, name, steps}, _from, state) do
    if Map.has_key?(state.workflows, name) do
      {:reply, {:error, :duplicate}, state}
    else
      {:reply, :ok, %{state | workflows: Map.put(state.workflows, name, steps)}}
    end
  end

  def handle_call({:execute, name, context}, _from, state) do
    reply =
      case Map.fetch(state.workflows, name) do
        {:ok, steps} -> {:ok, run_workflow(steps, context)}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.keys(state.workflows), state}
  end

  defp run_workflow(steps, initial_context) do
    start = System.monotonic_time(:millisecond)

    {status, context, completed, skipped, failed_step, failure_reason} =
      Enum.reduce_while(steps, {:ok, initial_context, [], []}, fn step, {:ok, ctx, done, skipped} ->
        case run_step(step, ctx) do
          {:ok, updated_ctx} ->
            {:cont, {:ok, updated_ctx, [step.name | done], skipped}}

          {:error, reason} when step.on_error == :skip ->
            {:cont, {:ok, ctx, done, [step.name | skipped]}}

          {:error, reason} ->
            {:halt, {:failed, ctx, done, skipped, step.name, reason}}
        end
      end)
      |> case do
        {:ok, ctx, done, skipped} -> {:completed, ctx, done, skipped, nil, nil}
        {:failed, ctx, done, skipped, step, reason} -> {:failed, ctx, done, skipped, step, reason}
      end

    duration = System.monotonic_time(:millisecond) - start

    final_status = cond do
      status == :failed -> :failed
      skipped != [] -> :partial
      true -> :completed
    end

    %ExecutionResult{
      status: final_status,
      context: context,
      completed_steps: Enum.reverse(completed),
      skipped_steps: Enum.reverse(skipped),
      failed_step: failed_step,
      failure_reason: failure_reason,
      duration_ms: duration
    }
  end

  defp run_step(%Step{run: fun, timeout_ms: timeout}, context) do
    task = Task.async(fn -> fun.(context) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end
end
```
