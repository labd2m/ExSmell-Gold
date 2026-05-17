```elixir
defmodule Config.EnvLoader do
  @moduledoc """
  Loads runtime configuration for the application from environment variables.
  Called during application startup to build the service configuration struct.

  Required environment variables:
    DATABASE_URL       - PostgreSQL connection string
    SECRET_KEY_BASE    - Phoenix secret key base (min 64 chars)
    API_SECRET         - Shared API authentication secret
    SMTP_HOST          - Outbound mail relay host
    SMTP_PORT          - Outbound mail relay port
    REDIS_URL          - Redis connection string for caching
    S3_BUCKET          - AWS S3 bucket name for file storage
    S3_REGION          - AWS S3 region
    STRIPE_SECRET_KEY  - Stripe secret API key
  """

  require Logger

  defstruct [
    :database_url,
    :secret_key_base,
    :api_secret,
    :smtp_host,
    :smtp_port,
    :redis_url,
    :s3_bucket,
    :s3_region,
    :stripe_secret_key,
    :env,
    :port,
    :log_level
  ]

  def load(env \\ Mix.env()) do
    %__MODULE__{
      database_url:      System.get_env("DATABASE_URL",      "ecto://postgres:postgres@localhost/app_dev"),
      secret_key_base:   System.get_env("SECRET_KEY_BASE",   String.duplicate("a", 64)),
      api_secret:        System.get_env("API_SECRET",         "default_insecure_api_secret"),
      smtp_host:         System.get_env("SMTP_HOST",          "localhost"),
      smtp_port:         System.get_env("SMTP_PORT",          "1025") |> String.to_integer(),
      redis_url:         System.get_env("REDIS_URL",          "redis://localhost:6379"),
      s3_bucket:         System.get_env("S3_BUCKET",          "app-local-bucket"),
      s3_region:         System.get_env("S3_REGION",          "us-east-1"),
      stripe_secret_key: System.get_env("STRIPE_SECRET_KEY",  "sk_test_placeholder"),
      env:               env,
      port:              System.get_env("PORT",               "4000") |> String.to_integer(),
      log_level:         System.get_env("LOG_LEVEL",          "info")  |> String.to_atom()
    }
  end

  def validate!(%__MODULE__{} = config) do
    errors = []

    errors =
      if byte_size(config.secret_key_base) < 64 do
        ["SECRET_KEY_BASE must be at least 64 characters" | errors]
      else
        errors
      end

    errors =
      if config.env == :prod and config.stripe_secret_key == "sk_test_placeholder" do
        ["STRIPE_SECRET_KEY must be set in production" | errors]
      else
        errors
      end

    errors =
      if config.env == :prod and config.api_secret == "default_insecure_api_secret" do
        ["API_SECRET must be set in production" | errors]
      else
        errors
      end

    if errors == [] do
      {:ok, config}
    else
      {:error, errors}
    end
  end

  def database_opts(%__MODULE__{database_url: url}) do
    url |> URI.parse() |> uri_to_opts()
  end

  defp uri_to_opts(%URI{host: host, port: port, path: "/" <> db, userinfo: userinfo}) do
    [username, password] = String.split(userinfo || ":", ":", parts: 2)

    [
      hostname: host,
      port:     port || 5432,
      database: db,
      username: username,
      password: password
    ]
  end

  defp uri_to_opts(_), do: []

  def smtp_opts(%__MODULE__{smtp_host: host, smtp_port: port}) do
    [relay: host, port: port, tls: :if_available]
  end

  def describe(%__MODULE__{env: env, port: port, smtp_host: smtp, s3_bucket: bucket}) do
    "Env=#{env} port=#{port} smtp=#{smtp} s3=#{bucket}"
  end
end
```
