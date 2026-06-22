**File:** `example_good_1321.md`

```elixir
defmodule Failover.Backend do
  @moduledoc "Represents a regional backend with its health status."

  @enforce_keys [:id, :region, :base_url, :priority]
  defstruct [:id, :region, :base_url, :priority, status: :healthy, failure_count: 0]

  @type health_status :: :healthy | :degraded | :unavailable
  @type t :: %__MODULE__{
          id: String.t(),
          region: String.t(),
          base_url: String.t(),
          priority: pos_integer(),
          status: health_status(),
          failure_count: non_neg_integer()
        }
end

defmodule Failover.Router do
  @moduledoc """
  A GenServer that maintains a list of regional backends, periodically
  health-checks them, and routes outgoing requests to the highest-priority
  available backend, falling over on failure.
  """

  use GenServer

  require Logger

  alias Failover.Backend

  @health_check_interval_ms :timer.seconds(15)
  @failure_threshold 3

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec route(binary()) :: {:ok, String.t()} | {:error, :no_healthy_backend}
  def route(path) when is_binary(path) do
    GenServer.call(__MODULE__, {:route, path})
  end

  @spec report_failure(String.t()) :: :ok
  def report_failure(backend_id) when is_binary(backend_id) do
    GenServer.cast(__MODULE__, {:report_failure, backend_id})
  end

  @spec report_success(String.t()) :: :ok
  def report_success(backend_id) when is_binary(backend_id) do
    GenServer.cast(__MODULE__, {:report_success, backend_id})
  end

  @spec backend_statuses() :: [%{id: String.t(), region: String.t(), status: Backend.health_status()}]
  def backend_statuses do
    GenServer.call(__MODULE__, :statuses)
  end

  @impl GenServer
  def init(opts) do
    backends = Keyword.fetch!(opts, :backends)
    health_checker = Keyword.get(opts, :health_checker, Failover.DefaultHealthChecker)
    schedule_health_checks()
    {:ok, %{backends: backends, health_checker: health_checker}}
  end

  @impl GenServer
  def handle_call({:route, path}, _from, %{backends: backends} = state) do
    case select_backend(backends) do
      nil ->
        {:reply, {:error, :no_healthy_backend}, state}

      backend ->
        {:reply, {:ok, backend.base_url <> path}, state}
    end
  end

  def handle_call(:statuses, _from, %{backends: backends} = state) do
    statuses = Enum.map(backends, &Map.take(&1, [:id, :region, :status]))
    {:reply, statuses, state}
  end

  @impl GenServer
  def handle_cast({:report_failure, id}, %{backends: backends} = state) do
    updated = update_backend(backends, id, &record_failure/1)
    {:noreply, %{state | backends: updated}}
  end

  def handle_cast({:report_success, id}, %{backends: backends} = state) do
    updated = update_backend(backends, id, &record_success/1)
    {:noreply, %{state | backends: updated}}
  end

  @impl GenServer
  def handle_info(:health_check, %{backends: backends, health_checker: checker} = state) do
    updated = Enum.map(backends, &run_health_check(&1, checker))
    schedule_health_checks()
    {:noreply, %{state | backends: updated}}
  end

  defp select_backend(backends) do
    backends
    |> Enum.filter(&(&1.status in [:healthy, :degraded]))
    |> Enum.sort_by(fn b -> {priority_rank(b.status), b.priority} end)
    |> List.first()
  end

  defp priority_rank(:healthy), do: 0
  defp priority_rank(:degraded), do: 1
  defp priority_rank(:unavailable), do: 2

  defp record_failure(%Backend{failure_count: count} = backend) do
    new_count = count + 1
    new_status = if new_count >= @failure_threshold, do: :unavailable, else: :degraded
    Logger.warning("Backend #{backend.id} failure #{new_count}/#{@failure_threshold}")
    %{backend | failure_count: new_count, status: new_status}
  end

  defp record_success(%Backend{} = backend) do
    %{backend | failure_count: 0, status: :healthy}
  end

  defp run_health_check(%Backend{} = backend, checker) do
    case checker.check(backend.base_url) do
      :ok ->
        if backend.status == :unavailable do
          Logger.info("Backend #{backend.id} recovered")
        end
        %{backend | status: :healthy, failure_count: 0}

      {:error, reason} ->
        Logger.warning("Health check failed for #{backend.id}: #{inspect(reason)}")
        record_failure(backend)
    end
  end

  defp update_backend(backends, id, transform_fn) do
    Enum.map(backends, fn b -> if b.id == id, do: transform_fn.(b), else: b end)
  end

  defp schedule_health_checks do
    Process.send_after(self(), :health_check, @health_check_interval_ms)
  end
end

defmodule Failover.DefaultHealthChecker do
  @moduledoc "Default health checker that performs an HTTP GET to /health."

  @spec check(String.t()) :: :ok | {:error, term()}
  def check(base_url) when is_binary(base_url) do
    url = String.to_charlist(base_url <> "/health")

    case :httpc.request(:get, {url, []}, [{:timeout, 3_000}], []) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 -> :ok
      {:ok, {{_, status, _}, _, _}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```
