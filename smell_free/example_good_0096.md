# File: `example_good_96.md`

```elixir
defmodule Scheduler.RecurringJob do
  @moduledoc """
  GenServer that executes a named job function on a fixed interval,
  tracking run history and surfacing the last execution outcome.

  Jobs are isolated in supervised Tasks to prevent a long-running or
  crashing job from disrupting the scheduler loop. Each job execution
  is guarded by a configurable wall-clock deadline.
  """

  use GenServer

  require Logger

  @default_timeout_ms 30_000
  @max_history_entries 20

  @type job_fn :: (-> :ok | {:error, term()})

  @type opts :: [
          interval_ms: pos_integer(),
          timeout_ms: pos_integer(),
          run_on_start: boolean()
        ]

  @type run_entry :: %{
          started_at: DateTime.t(),
          status: :ok | :error | :timeout,
          detail: term(),
          duration_ms: non_neg_integer()
        }

  @doc false
  def start_link({name, job_fn, opts}) when is_atom(name) and is_function(job_fn, 0) do
    GenServer.start_link(__MODULE__, {name, job_fn, opts}, name: via(name))
  end

  @doc """
  Returns the execution history for a named job, most recent first.
  """
  @spec history(atom()) :: [run_entry()]
  def history(name) when is_atom(name) do
    GenServer.call(via(name), :history)
  end

  @doc """
  Returns the result of the most recent execution of a named job.

  Returns `{:ok, run_entry}` or `{:error, :never_run}`.
  """
  @spec last_run(atom()) :: {:ok, run_entry()} | {:error, :never_run}
  def last_run(name) when is_atom(name) do
    GenServer.call(via(name), :last_run)
  end

  @doc """
  Triggers an immediate out-of-band execution of the job, bypassing
  the regular interval timer.
  """
  @spec run_now(atom()) :: :ok
  def run_now(name) when is_atom(name) do
    GenServer.cast(via(name), :run_now)
  end

  @impl GenServer
  def init({name, job_fn, opts}) do
    interval_ms = Keyword.fetch!(opts, :interval_ms)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    run_on_start = Keyword.get(opts, :run_on_start, false)

    state = %{
      name: name,
      job_fn: job_fn,
      interval_ms: interval_ms,
      timeout_ms: timeout_ms,
      history: []
    }

    if run_on_start, do: send(self(), :run)
    schedule(interval_ms)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:history, _from, state) do
    {:reply, state.history, state}
  end

  @impl GenServer
  def handle_call(:last_run, _from, %{history: []} = state) do
    {:reply, {:error, :never_run}, state}
  end

  @impl GenServer
  def handle_call(:last_run, _from, %{history: [latest | _]} = state) do
    {:reply, {:ok, latest}, state}
  end

  @impl GenServer
  def handle_cast(:run_now, state) do
    new_state = execute_job(state)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:run, state) do
    new_state = execute_job(state)
    schedule(state.interval_ms)
    {:noreply, new_state}
  end

  defp execute_job(state) do
    started_at = DateTime.utc_now()
    start_ms = System.monotonic_time(:millisecond)
    task = Task.async(state.job_fn)

    result =
      case Task.yield(task, state.timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, :ok} -> {:ok, nil}
        {:ok, {:error, reason}} -> {:error, reason}
        nil -> {:timeout, :timeout}
      end

    entry = build_entry(started_at, result, start_ms)

    Logger.info("Job #{state.name} completed with status #{entry.status} in #{entry.duration_ms}ms")

    %{state | history: prepend_bounded(entry, state.history)}
  end

  defp build_entry(started_at, {status, detail}, start_ms) do
    %{
      started_at: started_at,
      status: status,
      detail: detail,
      duration_ms: System.monotonic_time(:millisecond) - start_ms
    }
  end

  defp prepend_bounded(entry, history) do
    [entry | history] |> Enum.take(@max_history_entries)
  end

  defp schedule(interval_ms) do
    Process.send_after(self(), :run, interval_ms)
  end

  defp via(name), do: {:via, Registry, {Scheduler.Registry, name}}
end
```
