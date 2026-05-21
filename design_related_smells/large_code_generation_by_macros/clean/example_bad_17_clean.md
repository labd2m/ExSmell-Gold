```elixir
defmodule Webhooks.WebhookDSL do
  @moduledoc """
  Compile-time DSL for declaring outbound webhook endpoint configurations.

  Each webhook endpoint subscribes to one or more event types, authenticates
  deliveries with a signature secret, and carries retry/timeout settings.
  All parameters are validated at compile time and registered as module
  attributes consumed by the delivery worker.
  """

  @valid_algorithms  [:hmac_sha256, :hmac_sha512, :rsa_sha256]
  @valid_content_types ["application/json", "application/x-www-form-urlencoded"]

  defmacro defwebhook(webhook_name, opts) do
    quote do
      webhook = unquote(webhook_name)
      opts    = unquote(opts)

      unless is_atom(webhook) do
        raise ArgumentError,
              "webhook name must be an atom, got: #{inspect(webhook)}"
      end

      url = Keyword.fetch!(opts, :url)

      unless is_binary(url) and String.starts_with?(url, "https://") do
        raise ArgumentError,
              "webhook #{inspect(webhook)} :url must be a binary starting with 'https://'"
      end

      event_types = Keyword.fetch!(opts, :event_types)

      unless is_list(event_types) and event_types != [] do
        raise ArgumentError,
              "webhook #{inspect(webhook)} :event_types must be a non-empty list"
      end

      Enum.each(event_types, fn et ->
        unless is_binary(et) and String.contains?(et, ".") do
          raise ArgumentError,
                "webhook #{inspect(webhook)} each event_type must be a namespaced binary like 'payments.captured'"
        end
      end)

      algorithm = Keyword.get(opts, :algorithm, :hmac_sha256)

      unless algorithm in unquote(@valid_algorithms) do
        raise ArgumentError,
              "webhook #{inspect(webhook)} :algorithm must be one of #{inspect(unquote(@valid_algorithms))}"
      end

      secret = Keyword.fetch!(opts, :secret)

      unless is_binary(secret) and byte_size(secret) >= 32 do
        raise ArgumentError,
              "webhook #{inspect(webhook)} :secret must be a binary of at least 32 bytes"
      end

      content_type = Keyword.get(opts, :content_type, "application/json")

      unless content_type in unquote(@valid_content_types) do
        raise ArgumentError,
              "webhook #{inspect(webhook)} :content_type must be one of #{inspect(unquote(@valid_content_types))}"
      end

      max_retries = Keyword.get(opts, :max_retries, 5)

      unless is_integer(max_retries) and max_retries >= 0 do
        raise ArgumentError,
              "webhook #{inspect(webhook)} :max_retries must be a non-negative integer"
      end

      delivery_timeout_ms = Keyword.get(opts, :delivery_timeout_ms, 10_000)

      unless is_integer(delivery_timeout_ms) and delivery_timeout_ms > 0 do
        raise ArgumentError,
              "webhook #{inspect(webhook)} :delivery_timeout_ms must be a positive integer"
      end

      failure_threshold = Keyword.get(opts, :failure_threshold, 10)

      unless is_integer(failure_threshold) and failure_threshold > 0 do
        raise ArgumentError,
              "webhook #{inspect(webhook)} :failure_threshold must be a positive integer"
      end

      enabled = Keyword.get(opts, :enabled, true)

      unless is_boolean(enabled) do
        raise ArgumentError,
              "webhook #{inspect(webhook)} :enabled must be a boolean"
      end

      @webhook_endpoints %{
        name:                webhook,
        url:                 url,
        event_types:         event_types,
        algorithm:           algorithm,
        secret:              secret,
        content_type:        content_type,
        max_retries:         max_retries,
        delivery_timeout_ms: delivery_timeout_ms,
        failure_threshold:   failure_threshold,
        enabled:             enabled
      }
    end
  end

  defmacro __using__(_) do
    quote do
      import Webhooks.WebhookDSL, only: [defwebhook: 2]
      Module.register_attribute(__MODULE__, :webhook_endpoints, accumulate: true)
      @before_compile Webhooks.WebhookDSL
    end
  end

  defmacro __before_compile__(env) do
    endpoints = Module.get_attribute(env.module, :webhook_endpoints)

    quote do
      def webhook_endpoints, do: unquote(Macro.escape(endpoints))

      def webhook(name) do
        Enum.find(webhook_endpoints(), &(&1.name == name))
      end

      def webhooks_for_event(event_type) do
        Enum.filter(webhook_endpoints(), fn ep ->
          ep.enabled and event_type in ep.event_types
        end)
      end
    end
  end
end

defmodule Webhooks.PartnerEndpoints do
  use Webhooks.WebhookDSL

  defwebhook(:partner_a_payments,
    url: "https://partner-a.example.com/webhooks/payments",
    event_types: ["payments.captured", "payments.refunded", "payments.failed"],
    algorithm: :hmac_sha256,
    secret: "partner_a_secret_key_minimum_32_bytes!!",
    max_retries: 5,
    delivery_timeout_ms: 8_000,
    failure_threshold: 20,
    enabled: true
  )

  defwebhook(:partner_b_shipments,
    url: "https://partner-b.example.com/hooks/shipments",
    event_types: ["logistics.shipment_created", "logistics.shipment_delivered"],
    algorithm: :hmac_sha512,
    secret: "partner_b_secret_key_minimum_32_bytes!!",
    content_type: "application/json",
    max_retries: 3,
    delivery_timeout_ms: 12_000,
    failure_threshold: 10,
    enabled: true
  )

  defwebhook(:internal_audit_sink,
    url: "https://audit.internal.example.com/ingest",
    event_types: ["users.registered", "auth.password_reset_requested", "billing.invoice_voided"],
    algorithm: :hmac_sha256,
    secret: "internal_audit_secret_key_min_32_bytes!",
    max_retries: 10,
    delivery_timeout_ms: 5_000,
    failure_threshold: 50,
    enabled: true
  )

  defwebhook(:crm_integration,
    url: "https://crm.example.com/api/webhooks",
    event_types: ["users.registered", "billing.subscription_renewed"],
    algorithm: :hmac_sha256,
    secret: "crm_webhook_secret_key_minimum_32_bytes!",
    max_retries: 3,
    delivery_timeout_ms: 10_000,
    failure_threshold: 5,
    enabled: false
  )
end
```
