```elixir
defmodule MyApp.Tasks.DeadlineEnforcer do
  @moduledoc """
  A GenServer that monitors in-flight tasks for deadline expiry. Tasks
  register themselves with a deadline timestamp on start and deregister
  on completion. The enforcer polls registered tasks every second and
  sends a `{:deadline_exceeded, task_id}` message to the owning process
  when the current time exceeds the deadline, allowing the task to
  perform orderly shutdown.

  The enforcer itself never cancels or terminates task processes; policy
  decisions belong to the task owner.
  """

  use GenServer

  require Logger

  @poll_interval_ms 1_000

  @type task_id :: String.t()
  @type registration :: %{
          task_id: task_id(),
          owner_pid: pid(),
          deadline: DateTime.t(),
          registered_at: DateTime.t()
        }

  @doc "Starts the deadline enforcer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers `task_id` owned by the calling process with the given
  `deadline`. The owner receives `{:deadline_exceeded, task_id}` if the
  deadline passes before `deregister/1` is called.
  """
  @spec register(task_id(), DateTime.t()) :: :ok
  def register(task_id, %DateTime{} = deadline) when is_binary(task_id) do
    GenServer.cast(__MODULE__, {:register, task_id, self(), deadline})
  end

  @doc "Removes the registration for `task_id`, cancelling deadline enforcement."
  @spec deregister(task_id()) :: :ok
  def deregister(task_id) when is_binary(task_id) do
    GenServer.cast(__MODULE__, {:deregister, task_id})
  end

  @doc "Returns all currently registered tasks."
  @spec registered_tasks() :: [registration()]
  def registered_tasks do
    GenServer.call(__MODULE__, :registered_tasks)
  end

  @impl GenServer
  def init(_opts) do
    schedule_poll()
    {:ok, %{registrations: %{}}}
  end

  @impl GenServer
  def handle_cast({:register, task_id, owner_pid, deadline}, state) do
    entry = %{
      task_id: task_id,
      owner_pid: owner_pid,
      deadline: deadline,
      registered_at: DateTime.utc_now()
    }

    {:noreply, %{state | registrations: Map.put(state.registrations, task_id, entry)}}
  end

  @impl GenServer
  def handle_cast({:deregister, task_id}, state) do
    {:noreply, %{state | registrations: Map.delete(state.registrations, task_id)}}
  end

  @impl GenServer
  def handle_call(:registered_tasks, _from, state) do
    {:reply, Map.values(state.registrations), state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    now = DateTime.utc_now()
    {expired, active} = Enum.split_with(state.registrations, fn {_, r} -> deadline_passed?(r.deadline, now) end)

    Enum.each(expired, fn {task_id, reg} ->
      Logger.warning("task_deadline_exceeded", task_id: task_id)
      send(reg.owner_pid, {:deadline_exceeded, task_id})
    end)

    schedule_poll()
    {:noreply, %{state | registrations: Map.new(active)}}
  end

  @spec deadline_passed?(DateTime.t(), DateTime.t()) :: boolean()
  defp deadline_passed?(deadline, now) do
    DateTime.compare(now, deadline) != :lt
  end

  @spec schedule_poll() :: reference()
  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)
end
```
