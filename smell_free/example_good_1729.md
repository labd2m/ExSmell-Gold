```elixir
defmodule Observability.HealthChecker do
  @moduledoc """
  Periodically evaluates the health of registered application
  subsystems and maintains a current health status map.

  Health probes are registered at startup with a name and a zero-arity
  function. Each probe is executed on a configurable schedule and its
  result is stored in ETS for O(1) reads by external health endpoints.
  """

  use GenServer

  require Logger

  @table :health_checker_status
  @default_interval_ms 15_000

  @type probe_name :: atom()
  @type probe_fn :: (() -> :ok | {:error, term()})
  @type probe_status :: :healthy | {:unhealthy, term()} | :unknown
  @type probe_registration :: {probe_name(), probe_fn()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns the current health status for all registered probes.
  """
  @spec all_statuses() :: %{probe_name() => probe_status()}
  def all_statuses do
    :ets.tab2list(@table)
    |> Map.new()
  end

  @doc """
  Returns the health status for a specific probe by name.
  """
  @spec status(probe_name()) :: probe_status()
  def status(probe_name) when is_atom(probe_name) do
    case :ets.lookup(@table, probe_name) do
      [{^probe_name, value}] -> value
      [] -> :unknown
    end
  end

  @doc """
  Returns `true` only if all registered probes are currently healthy.
  """
  @spec healthy?() :: boolean()
  def healthy? do
    all_statuses()
    |> Map.values()
    |> Enum.all?(&(&1 == :healthy))
  end

  @impl GenServer
  def init(opts) do
    probes = Keyword.get(opts, :probes, [])
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    Enum.each(probes, fn {name, _fn} ->
      :ets.insert(@table, {name, :unknown})
    end)

    schedule_check(interval_ms)

    {:ok, %{probes: probes, interval_ms: interval_ms}}
  end

  @impl GenServer
  def handle_info(:run_checks, state) do
    run_all_probes(state.probes)
    schedule_check(state.interval_ms)
    {:noreply, state}
  end

  @spec run_all_probes([probe_registration()]) :: :ok
  defp run_all_probes(probes) do
    Enum.each(probes, &run_probe/1)
  end

  @spec run_probe(probe_registration()) :: :ok
  defp run_probe({name, probe_fn}) do
    result = safe_call(probe_fn)
    status = interpret_result(result)
    :ets.insert(@table, {name, status})

    if status != :healthy do
      Logger.warning("Health probe #{name} reported: #{inspect(status)}")
    end

    :ok
  end

  @spec safe_call(probe_fn()) :: :ok | {:error, term()}
  defp safe_call(probe_fn) do
    probe_fn.()
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec interpret_result(:ok | {:error, term()}) :: probe_status()
  defp interpret_result(:ok), do: :healthy
  defp interpret_result({:error, reason}), do: {:unhealthy, reason}

  @spec schedule_check(pos_integer()) :: reference()
  defp schedule_check(interval_ms) do
    Process.send_after(self(), :run_checks, interval_ms)
  end
end
```
