```elixir
defmodule Webhooks.DeliveryService do
  @moduledoc """
  Handles reliable webhook delivery: endpoint lookup, payload signing,
  HTTP dispatch, response validation, and delivery logging.
  """

  alias Webhooks.{
    EndpointRegistry,
    PayloadSigner,
    HttpClient,
    ResponseValidator,
    DeliveryLog
  }

  require Logger

  @timeout_ms 10_000
  @max_payload_bytes 1_048_576

  @doc """
  Delivers a webhook event `payload` to the registered endpoints for `subscription_id`.

  Returns `{:ok, delivery_record}` or a structured error.
  """
  @spec deliver_webhook(String.t(), map()) ::
          {:ok, map()}
          | {:error, :endpoint_not_found}
          | {:error, :payload_too_large}
          | {:error, :signing_failed}
          | {:error, :http_failed, non_neg_integer() | :timeout}
          | {:error, :invalid_response}
  def deliver_webhook(subscription_id, payload) do
    serialized = Jason.encode!(payload)

    if byte_size(serialized) > @max_payload_bytes do
      {:error, :payload_too_large}
    else
      with {:ok, endpoint}  <- EndpointRegistry.fetch(subscription_id),
           {:ok, signature} <- PayloadSigner.sign(serialized, endpoint.secret),
           {:ok, response}  <- HttpClient.post(endpoint.url, serialized, %{
                                 "Content-Type"      => "application/json",
                                 "X-Signature-256"   => signature,
                                 "X-Subscription-Id" => subscription_id
                               }, timeout: @timeout_ms),
           :ok              <- ResponseValidator.validate(response) do
        record = %{
          id:              Ecto.UUID.generate(),
          subscription_id: subscription_id,
          endpoint_url:    endpoint.url,
          status_code:     response.status,
          delivered_at:    DateTime.utc_now()
        }

        DeliveryLog.insert!(record)
        Logger.info("Webhook delivered to #{endpoint.url} [#{response.status}]")
        {:ok, record}
      else
        {:error, :not_found} ->
          Logger.warn("No endpoint registered for subscription #{subscription_id}")
          {:error, :endpoint_not_found}

        {:error, :sign, detail} ->
          Logger.error("Payload signing error: #{inspect(detail)}")
          {:error, :signing_failed}

        {:error, :http, status} when is_integer(status) ->
          Logger.warn("HTTP delivery failed with status #{status}")
          {:error, :http_failed, status}

        {:error, :http, :timeout} ->
          Logger.warn("HTTP delivery timed out after #{@timeout_ms}ms")
          {:error, :http_failed, :timeout}

        {:error, :response, _detail} ->
          Logger.warn("Endpoint returned invalid response body")
          {:error, :invalid_response}
      end
    end
  end
end
```
