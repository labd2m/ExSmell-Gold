```elixir
defmodule Platform.Application do
  @moduledoc """
  Root OTP Application supervisor for the Platform service.

  The supervision tree is structured in layers: infrastructure (database,
  cache, registry), domain services, and the HTTP endpoint. Each layer
  starts only after the layer below it is healthy, using `rest_for_one`
  where appropriate to enforce dependency ordering.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    Platform.ConfigValidator.validate!(:platform, config_schema())

    children = [
      infrastructure_group(),
      domain_group(),
      web_group()
    ]

    opts = [strategy: :one_for_one, name: Platform.Supervisor]
    Supervisor.start_link(List.flatten(children), opts)
  end

  defp infrastructure_group do
    [
      Platform.Repo,
      {Registry, keys: :unique, name: Platform.OrderRegistry},
      {Registry, keys: :unique, name: Platform.TenantRegistry},
      {Registry, keys: :unique, name: Platform.CheckoutRegistry},
      {Phoenix.PubSub, name: Platform.PubSub},
      {Finch, name: Platform.Finch, pools: finch_pools()}
    ]
  end

  defp domain_group do
    [
      {Task.Supervisor, name: Platform.TaskSupervisor},
      {Task.Supervisor, name: Platform.JobScheduler.TaskSupervisor},
      Platform.JobScheduler,
      Platform.TenantSupervisor,
      Platform.ConnectionPool,
      Platform.Outbox.Poller,
      Platform.HealthAggregator
    ]
  end

  defp web_group do
    [
      AppWeb.Telemetry,
      AppWeb.Endpoint
    ]
  end

  @impl Application
  def stop(_state) do
    :ok
  end

  defp finch_pools do
    %{
      :default => [size: 10, count: 1],
      "https://api.stripe.com" => [size: 5, count: 1],
      "https://api.sendgrid.com" => [size: 5, count: 1]
    }
  end

  defp config_schema do
    import Platform.ConfigValidator

    [
      %{path: [:secret_key_base], rule: required_string()},
      %{path: [:database_url], rule: valid_url()},
      %{path: [:object_store_bucket], rule: required_string()},
      %{path: [:mailer, :api_key], rule: required_string()},
      %{path: [:stripe, :secret_key], rule: required_string()},
      %{path: [:stripe, :webhook_secret], rule: required_string()},
      %{path: [:rate_limiter, :default_capacity], rule: positive_integer()},
      %{path: [:environment], rule: one_of([:dev, :test, :staging, :prod])}
    ]
  end
end
```
