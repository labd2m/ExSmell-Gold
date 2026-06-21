```elixir
defmodule MyAppWeb.Router do
  @moduledoc """
  Phoenix router for a versioned REST API. Each version scope is an
  independent module pipeline, ensuring that middleware changes for v3
  never inadvertently affect v1 or v2 consumers. Content negotiation is
  enforced by a shared Plug so every versioned pipeline inherits it without
  repetition. Internal health and metrics endpoints are separated from the
  public API surface and do not carry auth middleware.
  """

  use MyAppWeb, :router

  alias MyAppWeb.Plug.{
    ApiVersion,
    HmacAuth,
    RateLimit,
    RequestTracer
  }

  # ---------------------------------------------------------------------------
  # Pipelines
  # ---------------------------------------------------------------------------

  pipeline :api_base do
    plug :accepts, ["json"]
    plug RequestTracer
    plug ApiVersion
  end

  pipeline :authenticated do
    plug MyAppWeb.Plug.BearerAuth
  end

  pipeline :rate_limited do
    plug RateLimit, capacity: 500, window_ms: 60_000
  end

  pipeline :webhook_inbound do
    plug MyAppWeb.Plug.CacheRawBody
    plug HmacAuth, secret_key: Application.compile_env!(:my_app, :webhook_secret)
  end

  pipeline :internal do
    plug :accepts, ["json"]
    plug MyAppWeb.Plug.InternalNetworkGuard
  end

  # ---------------------------------------------------------------------------
  # Public API — versioned scopes
  # ---------------------------------------------------------------------------

  scope "/api/v1", MyAppWeb.V1 do
    pipe_through [:api_base, :authenticated, :rate_limited]

    resources "/accounts", AccountController, only: [:index, :show, :create]
    resources "/orders", OrderController, only: [:index, :show, :create]
    get "/orders/:id/status", OrderController, :status
  end

  scope "/api/v2", MyAppWeb.V2 do
    pipe_through [:api_base, :authenticated, :rate_limited]

    resources "/accounts", AccountController, only: [:index, :show, :create, :update]
    resources "/orders", OrderController
    resources "/subscriptions", SubscriptionController, only: [:index, :show, :create, :delete]
    get "/subscriptions/:id/invoices", SubscriptionController, :invoices
  end

  scope "/api/v3", MyAppWeb.V3 do
    pipe_through [:api_base, :authenticated, :rate_limited]

    resources "/accounts", AccountController
    resources "/orders", OrderController
    resources "/subscriptions", SubscriptionController
    resources "/products", ProductController, only: [:index, :show]
    resources "/webhooks", WebhookEndpointController
    post "/webhooks/:id/test", WebhookEndpointController, :test_delivery
  end

  # ---------------------------------------------------------------------------
  # Webhook ingestion — separate pipeline, no bearer auth
  # ---------------------------------------------------------------------------

  scope "/webhooks/inbound", MyAppWeb.Inbound do
    pipe_through [:api_base, :webhook_inbound]

    post "/stripe", StripeWebhookController, :receive
    post "/sendgrid", SendGridWebhookController, :receive
    post "/github", GithubWebhookController, :receive
  end

  # ---------------------------------------------------------------------------
  # Internal / operational endpoints
  # ---------------------------------------------------------------------------

  scope "/internal", MyAppWeb.Internal do
    pipe_through :internal

    get "/health", HealthController, :index
    get "/health/ready", HealthController, :ready
    get "/health/live", HealthController, :live
    get "/metrics", MetricsController, :index
  end
end
```
