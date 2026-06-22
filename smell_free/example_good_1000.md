```elixir
defmodule MyApp.Platform.BootstrapSupervisor do
  @moduledoc """
  The top-level application supervisor that starts all infrastructure and
  domain subsystems in dependency order. Child processes are partitioned
  into phases: infrastructure first (Repo, PubSub, Cache), then platform
  services (FeatureFlags, RateLimiter), and finally application-level
  workers and the web endpoint. Each phase uses `:one_for_one` so a
  crash in one child does not restart its siblings.
  """

  use Supervisor

  @doc "Starts the bootstrap supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children =
      infra_children() ++
        registry_children() ++
        platform_children() ++
        worker_children() ++
        web_children()

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec infra_children() :: [Supervisor.child_spec()]
  defp infra_children do
    [
      MyApp.Repo,
      {Phoenix.PubSub, name: MyApp.PubSub},
      MyApp.Cache,
      {Task.Supervisor, name: MyApp.Tasks.TaskSupervisor}
    ]
  end

  @spec registry_children() :: [Supervisor.child_spec()]
  defp registry_children do
    [
      {Registry, keys: :unique, name: MyApp.Inventory.Registry},
      {Registry, keys: :unique, name: MyApp.Subscriptions.Registry},
      {Registry, keys: :unique, name: MyApp.Documents.EditorRegistry},
      {Registry, keys: :unique, name: MyApp.Comms.RoomRegistry},
      {Registry, keys: :unique, name: MyApp.Platform.PluginRegistry}
    ]
  end

  @spec platform_children() :: [Supervisor.child_spec()]
  defp platform_children do
    [
      MyApp.FeatureFlags,
      MyApp.RateLimiter,
      MyApp.Billing.TaxCalculator,
      MyApp.Finance.CurrencyConverter,
      MyApp.Infra.SecretManager,
      MyApp.Infra.ClusterState
    ]
  end

  @spec worker_children() :: [Supervisor.child_spec()]
  defp worker_children do
    [
      MyApp.VideoEncoder.Pool,
      MyApp.Comms.MessageBroker,
      {DynamicSupervisor, name: MyApp.Tasks.WorkerSupervisor, strategy: :one_for_one},
      MyApp.Platform.PluginHostSupervisor,
      MyApp.Observability.HealthChecker,
      MyApp.Infra.GracefulShutdown,
      {Oban, Application.fetch_env!(:my_app, Oban)}
    ]
  end

  @spec web_children() :: [Supervisor.child_spec()]
  defp web_children do
    [
      MyApp.Telemetry.MetricsReporter,
      MyAppWeb.Endpoint
    ]
  end
end
```
