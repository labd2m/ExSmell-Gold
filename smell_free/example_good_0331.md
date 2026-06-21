```elixir
defmodule Database.PoolHealth do
  @moduledoc """
  Monitors the health of a named Ecto Repo's connection pool and
  publishes status change events via Phoenix.PubSub when the pool
  transitions between healthy and degraded states.

  The monitor probes the pool on a configurable interval by executing
  a cheap `SELECT 1` query. Consecutive failures exceeding a threshold
  trigger a `:degraded` status; recovery requires a run of consecutive
  successes before the pool is marked `:healthy` again. This hysteresis
  prevents flapping when a database is intermittently reachable.
  """

  use GenServer

  require Logger

  @type status :: :healthy | :degraded | :unknown

  @type opts :: [
          repo: module(),
          pubsub: atom(),
          topic: String.t(),
          probe_interval_ms: pos_integer(),
          failure_threshold: pos_integer(),
          recovery_threshold: pos_integer()
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec status(atom()) :: status()
  def status(name \\ __MODULE__) do
    GenServer.call(name, :status)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      repo: Keyword.fetch!(opts, :repo),
      pubsub: Keyword.get(opts, :pubsub, MyApp.PubSub),
      topic: Keyword.get(opts, :topic, "db:health"),
      probe_interval_ms: Keyword.get(opts, :probe_interval_ms, 15_000),
      failure_threshold: Keyword.get(opts, :failure_threshold, 3),
      recovery_threshold: Keyword.get(opts, :recovery_threshold, 2),
      status: :unknown,
      consecutive_failures: 0,
      consecutive_successes: 0
    }

    schedule_probe(state.probe_interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl GenServer
  def handle_info(:probe, state) do
    updated_state =
      case probe(state.repo) do
        :ok -> handle_success(state)
        {:error, _reason} -> handle_failure(state)
      end

    schedule_probe(state.probe_interval_ms)
    {:noreply, updated_state}
  end

  defp handle_success(%{status: current, consecutive_successes: s, recovery_threshold: threshold} = state) do
    updated = %{state | consecutive_failures: 0, consecutive_successes: s + 1}

    if current != :healthy and s + 1 >= threshold do
      transition(updated, :healthy)
    else
      updated
    end
  end

  defp handle_failure(%{status: current, consecutive_failures: f, failure_threshold: threshold} = state) do
    updated = %{state | consecutive_failures: f + 1, consecutive_successes: 0}

    if current != :degraded and f + 1 >= threshold do
      transition(updated, :degraded)
    else
      updated
    end
  end

  defp transition(state, new_status) do
    Logger.warning("DB pool health changed", repo: state.repo, from: state.status, to: new_status)

    Phoenix.PubSub.broadcast(state.pubsub, state.topic, {:db_health_changed, state.repo, new_status})

    %{state | status: new_status}
  end

  defp probe(repo) do
    repo.query("SELECT 1", [], timeout: 3_000)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp schedule_probe(interval) do
    Process.send_after(self(), :probe, interval)
  end
end
```
