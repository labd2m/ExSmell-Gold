```elixir
defmodule Observability.HealthChecker do
  @moduledoc """
  Runs periodic readiness probes against application dependencies and
  exposes the aggregate result. Each dependency declares its own probe
  module. Results are cached between sweeps so health endpoint handlers
  return immediately without blocking on live checks. The checker is
  supervised and recovers automatically from crashes.
  """

  use GenServer

  require Logger

  @type probe_name :: atom()
  @type probe_status :: :ok | :degraded | :down
  @type probe_result :: %{name: probe_name(), status: probe_status(), detail: String.t() | nil}
  @type aggregate :: %{status: probe_status(), probes: [probe_result()], checked_at: DateTime.t()}

  @sweep_interval_ms 30_000

  @doc "Starts the health checker and runs an initial probe sweep."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the cached aggregate result from the most recent sweep."
  @spec aggregate() :: aggregate()
  def aggregate, do: GenServer.call(__MODULE__, :aggregate)

  @doc "Triggers an immediate out-of-band probe sweep."
  @spec check_now() :: :ok
  def check_now, do: GenServer.cast(__MODULE__, :run_probes)

  @impl GenServer
  def init(opts) do
    probes = Keyword.get(opts, :probes, default_probes())
    interval = Keyword.get(opts, :interval_ms, @sweep_interval_ms)
    state = %{probes: probes, interval: interval, last_result: nil}
    send(self(), :run_probes)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:aggregate, _from, %{last_result: nil} = state) do
    {:reply, %{status: :down, probes: [], checked_at: DateTime.utc_now()}, state}
  end

  def handle_call(:aggregate, _from, state) do
    {:reply, state.last_result, state}
  end

  @impl GenServer
  def handle_cast(:run_probes, state) do
    new_state = run_sweep(state)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:run_probes, state) do
    new_state = run_sweep(state)
    Process.send_after(self(), :run_probes, state.interval)
    {:noreply, new_state}
  end

  defp run_sweep(state) do
    results = Enum.map(state.probes, &run_probe/1)
    aggregate = %{status: aggregate_status(results), probes: results, checked_at: DateTime.utc_now()}
    Logger.debug("[HealthChecker] sweep complete: #{aggregate.status}")
    %{state | last_result: aggregate}
  end

  defp run_probe({name, mod}) do
    case mod.check() do
      :ok -> %{name: name, status: :ok, detail: nil}
      {:degraded, detail} -> %{name: name, status: :degraded, detail: detail}
      {:error, detail} -> %{name: name, status: :down, detail: detail}
    end
  rescue
    e -> %{name: name, status: :down, detail: Exception.message(e)}
  end

  defp aggregate_status(results) do
    statuses = Enum.map(results, & &1.status)
    cond do
      :down in statuses -> :down
      :degraded in statuses -> :degraded
      true -> :ok
    end
  end

  defp default_probes do
    Application.get_env(:my_app, :health_probes, [])
  end
end
```
