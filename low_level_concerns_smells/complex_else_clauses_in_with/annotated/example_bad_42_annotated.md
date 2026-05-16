# Annotated Example 42 — Complex else clauses in with

## Metadata

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `deliver_webhook/2`, inside the `with` expression's `else` block
- **Affected function(s):** `deliver_webhook/2`
- **Short explanation:** Five steps in the webhook delivery pipeline each produce different error shapes. The single `else` block must handle all of them at once, coupling unrelated failure paths and obscuring which step originated a given pattern.

---

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
      # VALIDATION: SMELL START - Complex else clauses in with
      # VALIDATION: This is a smell because four with-clauses each fail with a
      # distinct shape ({:error, :not_found}, {:error, :sign, _},
      # {:error, :http, _}, {:error, :response, _}).
      # The flat else block collapses all into one list, making it impossible
      # to attribute a pattern to its originating step without cross-referencing.
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
      # VALIDATION: SMELL END
    end
  end
end
```
