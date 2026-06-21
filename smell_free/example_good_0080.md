```elixir
defmodule MyApp.Application do
  @moduledoc """
  Root OTP application entry point.

  Children are declared in dependency order so the supervisor starts
  infrastructure services before stateful workers, and stateful workers
  before the HTTP endpoint. The `:one_for_one` strategy confines failures
  to the faulting child without cascading restarts.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      {Phoenix.PubSub, name: MyApp.PubSub},
      {Registry, keys: :unique, name: MyApp.Registry},
      {Task.Supervisor, name: MyApp.TaskSupervisor},
      {Task.Supervisor, name: Webhooks.TaskSupervisor},
      {FeatureFlags.Store, []},
      {Auth.SessionStore, []},
      {Audit.Logger, [flush_interval_ms: 5_000, buffer_limit: 200]},
      {Throttle.Supervisor, []},
      MyAppWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end

  @impl Application
  def stop(_state), do: :ok
end

defmodule MyApp.HealthCheck do
  @moduledoc """
  Structured health check for container orchestration readiness probes.

  Each dependency is probed in isolation so a single failing service does
  not mask the health of others. The aggregated result expresses three
  states: `:healthy` (all pass), `:degraded` (non-critical failures),
  and `:unhealthy` (critical failures blocking traffic).
  """

  @type service_status :: :healthy | :degraded | :unhealthy

  @type result :: %{
          status: service_status(),
          services: %{atom() => service_status()},
          latency_ms: non_neg_integer(),
          checked_at: DateTime.t()
        }

  @spec run() :: result()
  def run do
    started = System.monotonic_time(:millisecond)

    services = %{
      database: probe_database(),
      feature_flags: probe_feature_flags(),
      session_store: probe_session_store()
    }

    elapsed = System.monotonic_time(:millisecond) - started

    %{
      status: aggregate_status(services),
      services: services,
      latency_ms: elapsed,
      checked_at: DateTime.utc_now()
    }
  end

  defp probe_database do
    case MyApp.Repo.query("SELECT 1", [], timeout: 2_000) do
      {:ok, _} -> :healthy
      _ -> :unhealthy
    end
  rescue
    _ -> :unhealthy
  end

  defp probe_feature_flags do
    _flags = FeatureFlags.Store.all()
    :healthy
  rescue
    _ -> :degraded
  end

  defp probe_session_store do
    _result = Auth.SessionStore.fetch("__healthcheck__")
    :healthy
  rescue
    _ -> :unhealthy
  end

  defp aggregate_status(services) do
    statuses = Map.values(services)

    cond do
      :unhealthy in statuses -> :unhealthy
      :degraded in statuses -> :degraded
      true -> :healthy
    end
  end
end

defmodule MyApp.Config do
  @moduledoc """
  Runtime configuration accessors for environment-dependent settings.

  All `Application.fetch_env!/2` calls are centralised here so that
  missing configuration is surfaced at startup with clear error messages
  rather than at the call site of an unrelated subsystem.
  """

  @spec database_url() :: String.t()
  def database_url, do: Application.fetch_env!(:my_app, :database_url)

  @spec secret_key_base() :: String.t()
  def secret_key_base, do: Application.fetch_env!(:my_app, :secret_key_base)

  @spec pubsub_name() :: atom()
  def pubsub_name, do: Application.get_env(:my_app, :pubsub_name, MyApp.PubSub)

  @spec task_supervisor() :: atom()
  def task_supervisor, do: Application.get_env(:my_app, :task_supervisor, MyApp.TaskSupervisor)
end
```
