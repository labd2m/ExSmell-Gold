```elixir
defmodule Observability.HealthChecker do
  @moduledoc """
  Aggregates health status from multiple registered subsystem probes.
  Returns a structured health report suitable for load balancer and monitoring endpoints.
  """

  use GenServer

  @type probe_name :: String.t()
  @type probe_fn :: (() -> :ok | {:error, String.t()})
  @type probe_result :: :healthy | {:degraded, String.t()} | :unhealthy
  @type health_report :: %{
    status: :healthy | :degraded | :unhealthy,
    probes: %{probe_name() => probe_result()},
    checked_at: DateTime.t()
  }

  @probe_timeout_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{probes: %{}}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec register_probe(probe_name(), probe_fn()) :: :ok
  def register_probe(name, probe_fn)
      when is_binary(name) and is_function(probe_fn, 0) do
    GenServer.call(__MODULE__, {:register, name, probe_fn})
  end

  @spec deregister_probe(probe_name()) :: :ok
  def deregister_probe(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:deregister, name})
  end

  @spec check() :: health_report()
  def check do
    GenServer.call(__MODULE__, :check, @probe_timeout_ms * 2)
  end

  @spec check_probe(probe_name()) :: {:ok, probe_result()} | {:error, :not_registered}
  def check_probe(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:check_one, name})
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:register, name, probe_fn}, _from, state) do
    {:reply, :ok, %{state | probes: Map.put(state.probes, name, probe_fn)}}
  end

  def handle_call({:deregister, name}, _from, state) do
    {:reply, :ok, %{state | probes: Map.delete(state.probes, name)}}
  end

  def handle_call(:check, _from, state) do
    results = run_all_probes(state.probes)
    report = build_report(results)
    {:reply, report, state}
  end

  def handle_call({:check_one, name}, _from, state) do
    case Map.get(state.probes, name) do
      nil -> {:reply, {:error, :not_registered}, state}
      probe_fn -> {:reply, {:ok, run_probe(probe_fn)}, state}
    end
  end

  @spec run_all_probes(%{probe_name() => probe_fn()}) :: %{probe_name() => probe_result()}
  defp run_all_probes(probes) do
    probes
    |> Enum.map(fn {name, probe_fn} ->
      task = Task.async(fn -> {name, run_probe(probe_fn)} end)
      {name, task}
    end)
    |> Enum.map(fn {name, task} ->
      case Task.yield(task, @probe_timeout_ms) || Task.shutdown(task) do
        {:ok, {^name, result}} -> {name, result}
        _ -> {name, :unhealthy}
      end
    end)
    |> Map.new()
  end

  @spec run_probe(probe_fn()) :: probe_result()
  defp run_probe(probe_fn) do
    case probe_fn.() do
      :ok -> :healthy
      {:error, reason} -> {:degraded, reason}
    end
  rescue
    error -> {:degraded, Exception.message(error)}
  end

  @spec build_report(%{probe_name() => probe_result()}) :: health_report()
  defp build_report(probe_results) do
    overall = compute_overall_status(probe_results)
    %{status: overall, probes: probe_results, checked_at: DateTime.utc_now()}
  end

  @spec compute_overall_status(%{probe_name() => probe_result()}) ::
          :healthy | :degraded | :unhealthy
  defp compute_overall_status(results) do
    statuses = Map.values(results)

    cond do
      Enum.any?(statuses, &(&1 == :unhealthy)) -> :unhealthy
      Enum.any?(statuses, &match?({:degraded, _}, &1)) -> :degraded
      true -> :healthy
    end
  end
end
```
