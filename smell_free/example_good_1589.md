```elixir
defmodule HealthCheck.Result do
  @moduledoc """
  The outcome of a single dependency health probe.
  """

  @type status :: :healthy | :degraded | :unhealthy

  @type t :: %__MODULE__{
          name: atom(),
          status: status(),
          latency_ms: non_neg_integer(),
          detail: String.t() | nil,
          checked_at: DateTime.t()
        }

  defstruct [:name, :status, :latency_ms, :detail, :checked_at]
end

defmodule HealthCheck.Behaviour do
  @moduledoc "Behaviour for individual health check probe implementations."

  @callback name() :: atom()
  @callback check() :: HealthCheck.Result.t()
end

defmodule HealthCheck.DatabaseProbe do
  @behaviour HealthCheck.Behaviour

  alias HealthCheck.Result
  alias MyApp.Repo

  @impl HealthCheck.Behaviour
  def name, do: :database

  @impl HealthCheck.Behaviour
  def check do
    start = System.monotonic_time(:millisecond)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {status, detail} =
      case Repo.query("SELECT 1", [], timeout: 2_000) do
        {:ok, _} -> {:healthy, nil}
        {:error, reason} -> {:unhealthy, inspect(reason)}
      end

    latency = System.monotonic_time(:millisecond) - start
    %Result{name: name(), status: status, latency_ms: latency, detail: detail, checked_at: now}
  end
end

defmodule HealthCheck.RedisProbe do
  @behaviour HealthCheck.Behaviour

  alias HealthCheck.Result

  @impl HealthCheck.Behaviour
  def name, do: :redis

  @impl HealthCheck.Behaviour
  def check do
    start = System.monotonic_time(:millisecond)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {status, detail} =
      case Redix.command(:redix, ["PING"], timeout: 2_000) do
        {:ok, "PONG"} -> {:healthy, nil}
        {:ok, unexpected} -> {:degraded, "unexpected response: #{unexpected}"}
        {:error, reason} -> {:unhealthy, inspect(reason)}
      end

    latency = System.monotonic_time(:millisecond) - start
    %Result{name: name(), status: status, latency_ms: latency, detail: detail, checked_at: now}
  end
end

defmodule HealthCheck.Supervisor do
  use Supervisor

  @moduledoc """
  Oversees the health check aggregator and all registered probe workers
  under a dedicated supervision subtree.
  """

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(opts) do
    probes = Keyword.get(opts, :probes, [HealthCheck.DatabaseProbe, HealthCheck.RedisProbe])

    children = [{HealthCheck.Aggregator, probes: probes}]
    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule HealthCheck.Aggregator do
  use GenServer

  alias HealthCheck.Result

  @check_interval_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec all_results() :: [Result.t()]
  def all_results, do: GenServer.call(__MODULE__, :results)

  @spec overall_status() :: Result.status()
  def overall_status, do: GenServer.call(__MODULE__, :overall)

  @impl GenServer
  def init(opts) do
    probes = Keyword.fetch!(opts, :probes)
    schedule_check()
    {:ok, %{probes: probes, results: %{}}}
  end

  @impl GenServer
  def handle_call(:results, _from, state) do
    {:reply, Map.values(state.results), state}
  end

  def handle_call(:overall, _from, state) do
    status = aggregate_status(Map.values(state.results))
    {:reply, status, state}
  end

  @impl GenServer
  def handle_info(:run_checks, state) do
    results =
      state.probes
      |> Task.async_stream(& &1.check(), timeout: 5_000, on_timeout: :kill_task)
      |> Enum.flat_map(fn
        {:ok, result} -> [result]
        {:exit, _} -> []
      end)
      |> Map.new(fn r -> {r.name, r} end)

    schedule_check()
    {:noreply, %{state | results: results}}
  end

  defp aggregate_status([]), do: :unhealthy
  defp aggregate_status(results) do
    cond do
      Enum.any?(results, &(&1.status == :unhealthy)) -> :unhealthy
      Enum.any?(results, &(&1.status == :degraded)) -> :degraded
      true -> :healthy
    end
  end

  defp schedule_check, do: Process.send_after(self(), :run_checks, @check_interval_ms)
end
```
