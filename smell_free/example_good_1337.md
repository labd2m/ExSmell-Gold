```elixir
defmodule Health.Aggregator do
  @moduledoc """
  Aggregates health check results from registered component probes
  to produce a unified readiness and liveness status.

  Each probe is a module implementing the `Health.Probe` behaviour.
  Probes are executed concurrently with individual timeouts to prevent
  a single slow dependency from blocking the entire health endpoint.
  """

  alias Health.Aggregator.{Probe, ProbeResult, AggregateResult}

  @default_timeout_ms 3_000

  @doc """
  Runs all registered probes concurrently and returns an aggregated result.
  """
  @spec check([module()], keyword()) :: AggregateResult.t()
  def check(probe_modules, opts \\ []) when is_list(probe_modules) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    results =
      probe_modules
      |> Task.async_stream(
        fn mod -> run_probe(mod, timeout) end,
        timeout: timeout + 500,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, :timeout} -> ProbeResult.timeout("unknown")
      end)

    AggregateResult.from_probe_results(results)
  end

  @doc """
  Runs a single probe by module name and returns its result.
  """
  @spec check_one(module(), keyword()) :: ProbeResult.t()
  def check_one(probe_module, opts \\ []) when is_atom(probe_module) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    run_probe(probe_module, timeout)
  end

  defp run_probe(module, timeout) do
    task = Task.async(fn -> Probe.run(module) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> ProbeResult.timeout(Probe.name(module))
    end
  end
end

defmodule Health.Aggregator.Probe do
  @moduledoc "Behaviour contract for health probe modules."

  alias Health.Aggregator.ProbeResult

  @callback name() :: String.t()
  @callback run() :: ProbeResult.t()

  @spec run(module()) :: Health.Aggregator.ProbeResult.t()
  def run(module), do: module.run()

  @spec name(module()) :: String.t()
  def name(module), do: module.name()
end

defmodule Health.Aggregator.ProbeResult do
  @moduledoc "Result of a single health probe execution."

  @enforce_keys [:probe_name, :status, :checked_at]
  defstruct [:probe_name, :status, :message, :checked_at, latency_ms: nil]

  @type status :: :healthy | :degraded | :unhealthy | :timeout
  @type t :: %__MODULE__{
          probe_name: String.t(),
          status: status(),
          message: String.t() | nil,
          checked_at: DateTime.t(),
          latency_ms: non_neg_integer() | nil
        }

  @spec healthy(String.t(), keyword()) :: t()
  def healthy(name, opts \\ []) do
    %__MODULE__{probe_name: name, status: :healthy,
                message: Keyword.get(opts, :message),
                latency_ms: Keyword.get(opts, :latency_ms),
                checked_at: DateTime.utc_now()}
  end

  @spec degraded(String.t(), String.t()) :: t()
  def degraded(name, message) do
    %__MODULE__{probe_name: name, status: :degraded, message: message, checked_at: DateTime.utc_now()}
  end

  @spec unhealthy(String.t(), String.t()) :: t()
  def unhealthy(name, message) do
    %__MODULE__{probe_name: name, status: :unhealthy, message: message, checked_at: DateTime.utc_now()}
  end

  @spec timeout(String.t()) :: t()
  def timeout(name) do
    %__MODULE__{probe_name: name, status: :timeout, message: "probe timed out", checked_at: DateTime.utc_now()}
  end
end

defmodule Health.Aggregator.AggregateResult do
  @moduledoc "Unified health status derived from all probe results."

  alias Health.Aggregator.ProbeResult

  @enforce_keys [:status, :probes, :checked_at]
  defstruct [:status, :probes, :checked_at]

  @type status :: :healthy | :degraded | :unhealthy
  @type t :: %__MODULE__{status: status(), probes: [ProbeResult.t()], checked_at: DateTime.t()}

  @spec from_probe_results([ProbeResult.t()]) :: t()
  def from_probe_results(results) when is_list(results) do
    overall =
      cond do
        Enum.any?(results, &(&1.status in [:unhealthy, :timeout])) -> :unhealthy
        Enum.any?(results, &(&1.status == :degraded)) -> :degraded
        true -> :healthy
      end

    %__MODULE__{status: overall, probes: results, checked_at: DateTime.utc_now()}
  end

  @spec healthy?(t()) :: boolean()
  def healthy?(%__MODULE__{status: :healthy}), do: true
  def healthy?(_), do: false

  @spec to_response_map(t()) :: map()
  def to_response_map(%__MODULE__{} = result) do
    %{
      status: result.status,
      checked_at: DateTime.to_iso8601(result.checked_at),
      probes: Enum.map(result.probes, fn p ->
        %{name: p.probe_name, status: p.status, message: p.message}
      end)
    }
  end
end
```
