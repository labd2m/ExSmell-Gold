```elixir
defmodule Reporting.ScheduledGenerator do
  @moduledoc """
  A GenServer that generates and delivers periodic reports on a fixed schedule.

  Report definitions are registered at runtime and include the data-gathering
  function, the delivery target (email, S3, webhook), and the cron-like schedule
  expressed as an interval. Reports run independently under a Task.Supervisor.
  """

  use GenServer

  require Logger

  @type report_name :: atom()
  @type report_spec :: %{
          name: report_name(),
          generate_fn: (-> {:ok, binary()} | {:error, term()}),
          deliver_fn: (binary() -> :ok | {:error, term()}),
          interval_ms: pos_integer(),
          format: :csv | :json | :pdf
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Registers a report definition. The first run is scheduled immediately
  after registration.
  """
  @spec register(report_spec()) :: :ok | {:error, :already_registered}
  def register(%{name: name} = spec) when is_atom(name) do
    GenServer.call(__MODULE__, {:register, spec})
  end

  @doc "Triggers an immediate out-of-schedule run for `report_name`."
  @spec run_now(report_name()) :: :ok | {:error, :not_found}
  def run_now(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:run_now, name})
  end

  @doc "Returns the list of registered report names."
  @spec registered_reports() :: [report_name()]
  def registered_reports, do: GenServer.call(__MODULE__, :list)

  @impl GenServer
  def init(opts) do
    task_sup = Keyword.get(opts, :task_supervisor, Reporting.TaskSupervisor)
    {:ok, %{reports: %{}, task_sup: task_sup}}
  end

  @impl GenServer
  def handle_call({:register, %{name: name} = spec}, _from, state) do
    if Map.has_key?(state.reports, name) do
      {:reply, {:error, :already_registered}, state}
    else
      schedule_report(name, spec.interval_ms)
      {:reply, :ok, put_in(state, [:reports, name], spec)}
    end
  end

  @impl GenServer
  def handle_call({:run_now, name}, _from, state) do
    case Map.get(state.reports, name) do
      nil -> {:reply, {:error, :not_found}, state}
      spec ->
        Task.Supervisor.start_child(state.task_sup, fn -> execute_report(spec) end)
        {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_call(:list, _from, state) do
    {:reply, Map.keys(state.reports), state}
  end

  @impl GenServer
  def handle_info({:run_report, name}, %{reports: reports, task_sup: task_sup} = state) do
    case Map.get(reports, name) do
      nil ->
        {:noreply, state}

      spec ->
        Task.Supervisor.start_child(task_sup, fn -> execute_report(spec) end)
        schedule_report(name, spec.interval_ms)
        {:noreply, state}
    end
  end

  defp execute_report(%{name: name, generate_fn: gen, deliver_fn: deliver, format: fmt} = _spec) do
    Logger.info("[ScheduledGenerator] Starting report", report: name, format: fmt)
    start = System.monotonic_time(:millisecond)

    result =
      case gen.() do
        {:ok, content} -> deliver.(content)
        {:error, reason} -> {:error, {:generation_failed, reason}}
      end

    duration = System.monotonic_time(:millisecond) - start

    case result do
      :ok ->
        Logger.info("[ScheduledGenerator] Report delivered", report: name, duration_ms: duration)
      {:error, reason} ->
        Logger.error("[ScheduledGenerator] Report failed", report: name, reason: inspect(reason), duration_ms: duration)
    end
  end

  defp schedule_report(name, interval_ms) do
    Process.send_after(self(), {:run_report, name}, interval_ms)
  end
end
```
