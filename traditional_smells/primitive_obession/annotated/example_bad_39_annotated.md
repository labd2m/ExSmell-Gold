# Annotated Example — Primitive Obsession

| Field | Value |
|---|---|
| **Smell name** | Primitive Obsession |
| **Expected smell location** | `Onboarding.WebhookManager` module — URL handling throughout |
| **Affected functions** | `register_endpoint/3`, `validate_endpoint/1`, `rotate_secret/2`, `deliver_event/3` |
| **Short explanation** | Webhook endpoint URLs are passed and stored as plain `String.t()` values rather than a `%WebhookEndpoint{scheme: :https, host: String.t(), path: String.t(), port: integer() | nil}` struct. Each function that needs the host, scheme, or path must manually parse the raw URL string, making TLS enforcement, host allowlisting, and URL normalisation ad-hoc and scattered. |

```elixir
defmodule Onboarding.WebhookManager do
  @moduledoc """
  Manages webhook endpoint registration, secret rotation, and event delivery
  for third-party integrations in the SaaS onboarding flow.
  """

  require Logger

  alias Onboarding.Repo
  alias Onboarding.Schema.{WebhookEndpoint, WebhookDelivery, OAuthClient}
  alias Onboarding.HMAC

  @max_endpoints_per_client 10
  @delivery_timeout_ms 8_000
  @max_retry_attempts 3

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because webhook destination URLs are plain
  # `String.t()` values like "https://api.partner.com/hooks/events" instead of
  # a %WebhookEndpoint{scheme: :https, host: "api.partner.com", path: "/hooks/events"}
  # struct. All security checks (HTTPS enforcement, private IP blocking,
  # host allowlisting) must parse the raw string inline with URI.parse/1,
  # spreading URL-handling logic across every function that touches the URL.

  @spec register_endpoint(OAuthClient.t(), String.t(), list(String.t())) ::
          {:ok, WebhookEndpoint.t()} | {:error, term()}
  def register_endpoint(%OAuthClient{} = client, endpoint_url, event_types)
      when is_binary(endpoint_url) and is_list(event_types) do
    with :ok <- validate_endpoint(endpoint_url),
         :ok <- check_endpoint_limit(client),
         secret <- HMAC.generate_secret(),
         uri <- URI.parse(endpoint_url),
         attrs <- %{
           client_id: client.id,
           url: endpoint_url,
           host: uri.host,
           scheme: uri.scheme,
           path: uri.path || "/",
           event_types: event_types,
           secret: secret,
           active: true,
           created_at: DateTime.utc_now()
         } do
      case %WebhookEndpoint{} |> WebhookEndpoint.changeset(attrs) |> Repo.insert() do
        {:ok, endpoint} ->
          Logger.info("Webhook registered: client=#{client.id} host=#{uri.host}")
          {:ok, endpoint}

        {:error, cs} ->
          {:error, cs}
      end
    end
  end

  @spec validate_endpoint(String.t()) :: :ok | {:error, term()}
  def validate_endpoint(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["https"] ->
        {:error, {:insecure_scheme, uri.scheme}}

      is_nil(uri.host) or uri.host == "" ->
        {:error, :missing_host}

      String.contains?(uri.host, ["localhost", "127.0.0.1", "0.0.0.0"]) ->
        {:error, :loopback_host_not_allowed}

      String.match?(uri.host, ~r/^10\.|^192\.168\.|^172\.(1[6-9]|2\d|3[01])\./) ->
        {:error, :private_ip_not_allowed}

      not String.contains?(uri.host, ".") ->
        {:error, {:invalid_host, uri.host}}

      not is_nil(uri.port) and uri.port not in [443, 8443] ->
        {:error, {:non_standard_port, uri.port}}

      true ->
        :ok
    end
  end

  @spec rotate_secret(WebhookEndpoint.t(), String.t()) ::
          {:ok, WebhookEndpoint.t()} | {:error, term()}
  def rotate_secret(%WebhookEndpoint{} = endpoint, reason) when is_binary(reason) do
    with :ok <- validate_endpoint(endpoint.url) do
      uri = URI.parse(endpoint.url)
      new_secret = HMAC.generate_secret()

      Logger.info("Secret rotated: endpoint=#{endpoint.id} host=#{uri.host} reason=#{reason}")

      endpoint
      |> WebhookEndpoint.changeset(%{
        secret: new_secret,
        secret_rotated_at: DateTime.utc_now(),
        rotation_reason: reason
      })
      |> Repo.update()
    end
  end

  @spec deliver_event(WebhookEndpoint.t(), String.t(), map()) ::
          {:ok, WebhookDelivery.t()} | {:error, term()}
  def deliver_event(%WebhookEndpoint{} = endpoint, event_type, payload)
      when is_binary(event_type) and is_map(payload) do
    uri = URI.parse(endpoint.url)
    body = Jason.encode!(payload)
    signature = HMAC.sign(body, endpoint.secret)

    case HTTPClient.post(endpoint.url, body,
           headers: [
             {"X-Webhook-Signature", signature},
             {"X-Webhook-Event", event_type},
             {"X-Webhook-Host-Hint", uri.host}
           ],
           timeout: @delivery_timeout_ms
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        record_delivery(endpoint, event_type, :success, status)

      {:ok, %{status: status}} ->
        Logger.warning("Webhook non-2xx: endpoint=#{endpoint.id} url=#{endpoint.url} status=#{status}")
        record_delivery(endpoint, event_type, :failed, status)

      {:error, reason} ->
        Logger.error("Webhook delivery error: #{endpoint.url} reason=#{inspect(reason)}")
        {:error, :delivery_failed}
    end
  end

  # VALIDATION: SMELL END

  ## Private helpers

  defp check_endpoint_limit(%OAuthClient{} = client) do
    count = Repo.aggregate(WebhookEndpoint, :count, :id, client_id: client.id)

    if count >= @max_endpoints_per_client do
      {:error, {:endpoint_limit_reached, @max_endpoints_per_client}}
    else
      :ok
    end
  end

  defp record_delivery(endpoint, event_type, status, http_status) do
    attrs = %{
      webhook_endpoint_id: endpoint.id,
      event_type: event_type,
      status: status,
      http_status: http_status,
      delivered_at: DateTime.utc_now()
    }

    %WebhookDelivery{} |> WebhookDelivery.changeset(attrs) |> Repo.insert()
  end
end
```
