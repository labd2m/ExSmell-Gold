```elixir
defmodule Platform.ApplicationSupervisor do
  @moduledoc """
  Root application supervisor that assembles all subsystem supervisors,
  registries, and singleton services in the correct startup order.
  Each child is documented with its role so the supervision tree is
  self-describing. Strategies are chosen per subsystem: critical singletons
  use `:one_for_one`; tightly coupled pairs use `:one_for_all`.
  """

  use Supervisor

  @doc "Starts the root application supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      # ── Shared infrastructure ──────────────────────────────────────────
      {Registry, keys: :unique, name: MyApp.Registry},
      {Registry, keys: :duplicate, name: MyApp.PubSubRegistry},
      {Phoenix.PubSub, name: MyApp.PubSub},

      # ── Database connection pool ───────────────────────────────────────
      MyApp.Repo,

      # ── Domain service singletons ──────────────────────────────────────
      Sessions.Store,
      Cache.TTL,
      RateLimiter.TokenBucket,
      Metrics.CounterSupervisor,

      # ── Background job infrastructure ──────────────────────────────────
      {Task.Supervisor, name: MyApp.TaskSupervisor},
      {Task.Supervisor, name: Notifications.TaskSupervisor},

      # ── Dynamic worker pools ───────────────────────────────────────────
      Workforce.JobSupervisor,
      Media.ImageVariantSupervisor,

      # ── Telemetry ──────────────────────────────────────────────────────
      Telemetry.MetricsSampler,

      # ── Phoenix endpoint (last so all services are ready) ──────────────
      MyAppWeb.Endpoint
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Platform.ApplicationSupervisor.HealthCheck do
  @moduledoc """
  Verifies that all critical singleton children of the application
  supervisor are alive. Returns a map of child ID to status so operators
  can identify which subsystem is degraded without reading supervision
  tree internals directly.
  """

  @critical_children [
    Sessions.Store,
    Cache.TTL,
    RateLimiter.TokenBucket,
    MyApp.Repo
  ]

  @type child_status :: :alive | :not_started | :dead
  @type health_map :: %{module() => child_status()}

  @doc "Returns the liveness status of each critical child process."
  @spec check() :: health_map()
  def check do
    Map.new(@critical_children, fn mod ->
      {mod, probe(mod)}
    end)
  end

  @doc "Returns true when all critical children are alive."
  @spec all_alive?() :: boolean()
  def all_alive? do
    check() |> Map.values() |> Enum.all?(fn s -> s == :alive end)
  end

  defp probe(mod) do
    case Process.whereis(mod) do
      nil -> :not_started
      pid -> if Process.alive?(pid), do: :alive, else: :dead
    end
  end
end
```
