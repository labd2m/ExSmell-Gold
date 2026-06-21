```elixir
defmodule MyApp.Application do
  @moduledoc """
  The OTP Application entry point. Children are declared in the exact order
  they must start, respecting dependency relationships: infrastructure first,
  then domain services, then external-facing endpoints last. Each child is
  documented with a brief rationale for its position in the tree so the
  startup sequence remains understandable as the application grows.
  """

  use Application

  require Logger

  @impl Application
  def start(_type, _args) do
    MyApp.Config.load!()

    children = [
      # -------------------------------------------------------------------------
      # 1. Core infrastructure — no application dependencies
      # -------------------------------------------------------------------------

      # PostgreSQL connection pool. Must be ready before any Ecto queries.
      MyApp.Repo,

      # PubSub cluster. Required by Phoenix Channels, Presence, and the event bus.
      {Phoenix.PubSub, name: MyApp.PubSub},

      # In-process pub/sub event bus backed by Registry.
      Platform.EventBus.child_spec([]),

      # -------------------------------------------------------------------------
      # 2. Caches and warm-up processes
      # -------------------------------------------------------------------------

      # Feature flag ETS cache. Warms from DB on init; all callers depend on it.
      {Task, fn -> Platform.FeatureFlags.init_cache() end},

      # GeoIP database loader. Reads MaxMind DB into memory for sub-ms lookups.
      Geo.IpLookup,

      # RBAC permission cache. ETS-backed with PubSub invalidation.
      {Task, fn -> Platform.Authorization.init_cache() end},

      # -------------------------------------------------------------------------
      # 3. Supervised background processes
      # -------------------------------------------------------------------------

      # OAuth token cache with TTL-based eviction.
      Auth.TokenCache,

      # CDN invalidation batcher. Collects paths and flushes in windows.
      Content.CacheInvalidator,

      # Health check poller. Probes dependencies every 30 s.
      Observability.HealthCheck,

      # -------------------------------------------------------------------------
      # 4. Worker and job processing infrastructure
      # -------------------------------------------------------------------------

      # Task supervisor for fire-and-forget async work (audit logs, CSV rows, etc.)
      {Task.Supervisor, name: MyApp.TaskSupervisor},

      # Oban job queue. Depends on Repo being ready.
      {Oban, Application.fetch_env!(:my_app, Oban)},

      # Dynamic supervisor for per-tenant ingestion workers.
      Ingestion.TenantSupervisor,

      # Registry for circuit breakers.
      {Registry, keys: :unique, name: Infrastructure.CircuitBreakerRegistry},

      # -------------------------------------------------------------------------
      # 5. Telemetry and metrics
      # -------------------------------------------------------------------------

      # Prometheus reporter. Scrape endpoint on port 9568.
      Observability.MetricsReporter.child_spec(port: metrics_port()),

      # -------------------------------------------------------------------------
      # 6. Web endpoints — last because they depend on everything above
      # -------------------------------------------------------------------------

      # Main Phoenix HTTP endpoint.
      MyAppWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    result = Supervisor.start_link(children, opts)

    if match?({:ok, _}, result) do
      Logger.info("Application started",
        env: Application.get_env(:my_app, :env),
        node: Node.self()
      )
    end

    result
  end

  @impl Application
  def stop(_state) do
    Logger.info("Application stopping", node: Node.self())
    :ok
  end

  @impl Application
  def config_change(changed, _new, removed) do
    MyAppWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp metrics_port do
    Application.get_env(:my_app, :metrics_port, 9568)
  end
end
```
