# Annotated Example — Compile-time Global Configuration

## Metadata

- **Smell:** Compile-time global configuration
- **Expected Smell Location:** Module attribute `@max_delivery_attempts` defined via `Application.fetch_env!/2` at the top of the module body
- **Affected Function(s):** `deliver/2`, `schedule_retry/2`
- **Explanation:** `Application.fetch_env!/2` is called at compile-time to resolve the maximum webhook delivery attempt count and assign it to `@max_delivery_attempts`. Because `:webhooks` has not been loaded at compilation time, Elixir raises an `ArgumentError` or a warning. The integer is baked into the beam, so tuning retry behaviour in production is not possible without recompiling.

---

```elixir
defmodule Webhooks.DeliveryWorker do
  @moduledoc """
  Delivers outbound webhook payloads to subscriber endpoints.
  Failed deliveries are retried with exponential back-off up to a
  configurable maximum number of attempts. Exhausted deliveries
  are moved to a dead-letter log for manual inspection.
  """

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 runs at
  # VALIDATION: module-compilation time. The :webhooks OTP application is not
  # VALIDATION: yet loaded, so Elixir raises:
  # VALIDATION:   ** (ArgumentError) could not fetch application environment
  # VALIDATION:     :max_delivery_attempts for application :webhooks
  # VALIDATION: The resolved integer is frozen in the bytecode, so operators
  # VALIDATION: cannot increase or decrease the retry cap without recompiling.
  @max_delivery_attempts Application.fetch_env!(:webhooks, :max_delivery_attempts)
  # VALIDATION: SMELL END

  @initial_backoff_ms 1_000
  @backoff_multiplier 2
  @max_backoff_ms 300_000
  @request_timeout_ms 15_000
  @signature_header "X-Webhook-Signature"

  @type delivery_id :: String.t()
  @type endpoint :: String.t()
  @type payload :: map()

  @spec deliver(delivery_id(), map()) :: :ok | {:error, atom()}
  def deliver(delivery_id, delivery) do
    %{
      endpoint: endpoint,
      payload: payload,
      attempt: attempt,
      subscription_id: subscription_id,
      secret: secret
    } = delivery

    Logger.debug("Attempting webhook delivery",
      delivery_id: delivery_id,
      attempt: attempt,
      endpoint: endpoint
    )

    case post(endpoint, payload, secret) do
      {:ok, status} when status in 200..299 ->
        mark_delivered(delivery_id, attempt)
        Logger.info("Webhook delivered", delivery_id: delivery_id, attempt: attempt)
        :ok

      {:ok, status} ->
        Logger.warning("Webhook rejected by endpoint",
          delivery_id: delivery_id,
          status: status,
          attempt: attempt
        )

        handle_failure(delivery_id, delivery, {:rejected, status})

      {:error, reason} ->
        Logger.warning("Webhook delivery failed",
          delivery_id: delivery_id,
          reason: inspect(reason),
          attempt: attempt
        )

        handle_failure(delivery_id, delivery, reason)
    end
  end

  @spec schedule_retry(delivery_id(), map()) :: :ok | {:error, :exhausted}
  def schedule_retry(delivery_id, delivery) do
    attempt = delivery.attempt

    if attempt >= @max_delivery_attempts do
      Logger.error("Webhook delivery exhausted",
        delivery_id: delivery_id,
        max_attempts: @max_delivery_attempts
      )

      dead_letter_log().record(delivery_id, delivery)
      {:error, :exhausted}
    else
      delay_ms = compute_backoff(attempt)

      Logger.info("Scheduling webhook retry",
        delivery_id: delivery_id,
        attempt: attempt + 1,
        delay_ms: delay_ms
      )

      queue().schedule(delivery_id, Map.put(delivery, :attempt, attempt + 1), delay_ms)
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp handle_failure(delivery_id, delivery, _reason) do
    schedule_retry(delivery_id, delivery)
  end

  defp post(endpoint, payload, secret) do
    body = Jason.encode!(payload)
    signature = sign_payload(body, secret)

    headers = [
      {"Content-Type", "application/json"},
      {@signature_header, "sha256=#{signature}"}
    ]

    case http_client().post(endpoint, body, headers, timeout: @request_timeout_ms) do
      {:ok, %{status: status}} -> {:ok, status}
      {:error, _} = err -> err
    end
  end

  defp sign_payload(body, secret) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end

  defp compute_backoff(attempt) do
    raw = @initial_backoff_ms * :math.pow(@backoff_multiplier, attempt - 1)
    jitter = :rand.uniform(trunc(raw * 0.1))
    min(trunc(raw) + jitter, @max_backoff_ms)
  end

  defp mark_delivered(delivery_id, attempt) do
    delivery_log().record_success(delivery_id, attempt)
  end

  defp http_client, do: Application.get_env(:webhooks, :http_client, Webhooks.HttpClient)
  defp queue, do: Application.get_env(:webhooks, :queue, Webhooks.Queue)
  defp dead_letter_log, do: Application.get_env(:webhooks, :dead_letter_log, Webhooks.DeadLetterLog)
  defp delivery_log, do: Application.get_env(:webhooks, :delivery_log, Webhooks.DeliveryLog)
end
```
