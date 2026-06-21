```elixir
defmodule Router.Upstream do
  @moduledoc false

  @type t :: %__MODULE__{
          id: atom(),
          url: String.t(),
          weight: pos_integer(),
          healthy: boolean(),
          consecutive_failures: non_neg_integer()
        }

  defstruct [:id, :url, healthy: true, consecutive_failures: 0, weight: 1]
end

defmodule Router.UpstreamRouter do
  @moduledoc """
  Routes outbound requests to a pool of upstream services using weighted
  round-robin among healthy members.

  Each upstream is health-checked before selection. After
  `failure_threshold` consecutive failures the upstream is marked
  unhealthy and skipped until a background probe succeeds. If all
  upstreams are unhealthy the router returns `{:error, :no_healthy_upstream}`
  rather than sending to a known-bad host.
  """

  use GenServer

  alias Router.Upstream

  @type opts :: [
          upstreams: [Upstream.t()],
          failure_threshold: pos_integer(),
          probe_interval_ms: pos_integer()
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec next() :: {:ok, Upstream.t()} | {:error, :no_healthy_upstream}
  def next, do: GenServer.call(__MODULE__, :next)

  @spec report_success(atom()) :: :ok
  def report_success(upstream_id) when is_atom(upstream_id) do
    GenServer.cast(__MODULE__, {:success, upstream_id})
  end

  @spec report_failure(atom()) :: :ok
  def report_failure(upstream_id) when is_atom(upstream_id) do
    GenServer.cast(__MODULE__, {:failure, upstream_id})
  end

  @spec health_summary() :: [%{id: atom(), healthy: boolean(), failures: non_neg_integer()}]
  def health_summary, do: GenServer.call(__MODULE__, :health_summary)

  @impl GenServer
  def init(opts) do
    upstreams = Keyword.fetch!(opts, :upstreams)
    threshold = Keyword.get(opts, :failure_threshold, 3)
    probe_interval = Keyword.get(opts, :probe_interval_ms, 30_000)

    schedule_probe(probe_interval)

    state = %{
      upstreams: upstreams,
      index: 0,
      failure_threshold: threshold,
      probe_interval_ms: probe_interval
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:next, _from, state) do
    healthy = Enum.filter(state.upstreams, & &1.healthy)

    case healthy do
      [] ->
        {:reply, {:error, :no_healthy_upstream}, state}

      candidates ->
        idx = rem(state.index, length(candidates))
        upstream = Enum.at(candidates, idx)
        {:reply, {:ok, upstream}, %{state | index: state.index + 1}}
    end
  end

  def handle_call(:health_summary, _from, state) do
    summary = Enum.map(state.upstreams, fn u ->
      %{id: u.id, healthy: u.healthy, failures: u.consecutive_failures}
    end)
    {:reply, summary, state}
  end

  @impl GenServer
  def handle_cast({:success, id}, state) do
    updated = update_upstream(state.upstreams, id, fn u ->
      %{u | consecutive_failures: 0, healthy: true}
    end)
    {:noreply, %{state | upstreams: updated}}
  end

  def handle_cast({:failure, id}, state) do
    updated = update_upstream(state.upstreams, id, fn u ->
      failures = u.consecutive_failures + 1
      %{u | consecutive_failures: failures, healthy: failures < state.failure_threshold}
    end)
    {:noreply, %{state | upstreams: updated}}
  end

  @impl GenServer
  def handle_info(:probe, state) do
    updated = Enum.map(state.upstreams, fn upstream ->
      if upstream.healthy, do: upstream, else: probe(upstream)
    end)
    schedule_probe(state.probe_interval_ms)
    {:noreply, %{state | upstreams: updated}}
  end

  defp probe(%Upstream{} = upstream) do
    case :httpc.request(:get, {to_charlist(upstream.url <> "/health"), []}, [timeout: 2000], []) do
      {:ok, {{_, 200, _}, _, _}} -> %{upstream | healthy: true, consecutive_failures: 0}
      _ -> upstream
    end
  end

  defp update_upstream(upstreams, id, fun) do
    Enum.map(upstreams, fn u -> if u.id == id, do: fun.(u), else: u end)
  end

  defp schedule_probe(interval), do: Process.send_after(self(), :probe, interval)
end
```
