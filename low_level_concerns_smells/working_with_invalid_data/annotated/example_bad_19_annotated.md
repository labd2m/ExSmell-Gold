# Code Smell Annotation

- **Smell name:** Working with invalid data
- **Expected smell location:** `WebhookDispatcher.schedule_retry/3`, where `retry_delay_ms` is passed to `Process.send_after/3`
- **Affected function(s):** `schedule_retry/3`
- **Short explanation:** The `retry_delay_ms` parameter is passed directly to `Process.send_after/3`, which requires an integer number of milliseconds. If a caller passes a float or a string (e.g., coming from a config file that was not correctly parsed), `Process.send_after/3` raises a `BadArgumentError` deep inside the OTP runtime, with no clue that the original bad value came from the `schedule_retry/3` call.

```elixir
defmodule MyApp.Integrations.WebhookDispatcher do
  @moduledoc """
  Dispatches outbound webhook events to registered subscriber endpoints.
  Implements exponential backoff retry logic with configurable jitter and
  dead-letter queuing for permanently failed deliveries.
  """

  use GenServer

  require Logger

  alias MyApp.Integrations.{WebhookSubscription, DeliveryLog, DeadLetterQueue}

  @default_timeout_ms 5_000
  @max_attempts 5
  @base_backoff_ms 1_000
  @jitter_range_ms 500

  @type delivery_opts :: [
          timeout_ms: pos_integer(),
          headers: map(),
          hmac_secret: String.t() | nil
        ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec dispatch(String.t(), String.t(), map(), delivery_opts()) ::
          {:ok, String.t()} | {:error, atom()}
  def dispatch(subscription_id, event_type, payload, opts \\ []) do
    GenServer.call(__MODULE__, {:dispatch, subscription_id, event_type, payload, opts})
  end

  @spec schedule_retry(String.t(), pos_integer(), term()) :: :ok
  def schedule_retry(delivery_id, attempt_number, retry_delay_ms) do
    # VALIDATION: SMELL START - Working with invalid data
    # VALIDATION: This is a smell because `retry_delay_ms` is passed directly to
    # VALIDATION: `Process.send_after/3` without checking it is an integer.
    # VALIDATION: Process.send_after/3 requires a non-negative integer for the delay.
    # VALIDATION: If a caller passes a float (e.g., 1500.0) or a string ("1500"),
    # VALIDATION: the function will raise a BadArgumentError inside the OTP runtime
    # VALIDATION: with a message that does not mention schedule_retry or the caller.
    Process.send_after(self(), {:retry, delivery_id, attempt_number}, retry_delay_ms)
    # VALIDATION: SMELL END

    Logger.debug(
      "Retry scheduled: delivery=#{delivery_id} attempt=#{attempt_number} delay=#{retry_delay_ms}ms"
    )

    :ok
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    {:ok, %{in_flight: %{}, pending_retries: %{}}}
  end

  @impl true
  def handle_call({:dispatch, subscription_id, event_type, payload, opts}, _from, state) do
    with {:ok, subscription} <- WebhookSubscription.fetch(subscription_id) do
      delivery_id = Ecto.UUID.generate()
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      extra_headers = Keyword.get(opts, :headers, %{})

      body = Jason.encode!(payload)
      signature = sign_payload(body, subscription.secret)

      headers =
        Map.merge(extra_headers, %{
          "Content-Type" => "application/json",
          "X-Webhook-Signature" => signature,
          "X-Webhook-Event" => event_type,
          "X-Delivery-ID" => delivery_id
        })

      DeliveryLog.record_attempt(delivery_id, subscription_id, event_type, 1)

      case send_http_request(subscription.url, body, headers, timeout_ms) do
        {:ok, status} when status in 200..299 ->
          DeliveryLog.mark_success(delivery_id, status)
          {:reply, {:ok, delivery_id}, state}

        {:ok, status} ->
          Logger.warning("Webhook delivery failed: status=#{status} delivery=#{delivery_id}")
          maybe_retry(delivery_id, 1, state)
          {:reply, {:ok, delivery_id}, state}

        {:error, reason} ->
          Logger.error("Webhook delivery error: #{inspect(reason)} delivery=#{delivery_id}")
          maybe_retry(delivery_id, 1, state)
          {:reply, {:ok, delivery_id}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:retry, delivery_id, attempt}, state) do
    Logger.info("Retrying webhook delivery: #{delivery_id} attempt=#{attempt}")

    with {:ok, log} <- DeliveryLog.fetch(delivery_id),
         {:ok, subscription} <- WebhookSubscription.fetch(log.subscription_id) do
      body = log.payload_json
      headers = %{"Content-Type" => "application/json", "X-Delivery-ID" => delivery_id}

      DeliveryLog.record_attempt(delivery_id, log.subscription_id, log.event_type, attempt)

      case send_http_request(subscription.url, body, headers, @default_timeout_ms) do
        {:ok, status} when status in 200..299 ->
          DeliveryLog.mark_success(delivery_id, status)

        _ when attempt < @max_attempts ->
          maybe_retry(delivery_id, attempt + 1, state)

        _ ->
          Logger.error("Webhook permanently failed after #{attempt} attempts: #{delivery_id}")
          DeliveryLog.mark_failed(delivery_id)
          DeadLetterQueue.enqueue(delivery_id)
      end
    end

    {:noreply, state}
  end

  # Private helpers

  defp maybe_retry(delivery_id, attempt, _state) when attempt <= @max_attempts do
    delay = compute_backoff(attempt)
    schedule_retry(delivery_id, attempt + 1, delay)
  end

  defp maybe_retry(delivery_id, _attempt, _state) do
    DeliveryLog.mark_failed(delivery_id)
    DeadLetterQueue.enqueue(delivery_id)
  end

  defp compute_backoff(attempt) do
    base = @base_backoff_ms * :math.pow(2, attempt - 1)
    jitter = :rand.uniform(@jitter_range_ms)
    trunc(base) + jitter
  end

  defp send_http_request(url, body, headers, timeout_ms) do
    case :httpc.request(:post, {String.to_charlist(url), headers, 'application/json', body},
           [{:timeout, timeout_ms}], []) do
      {:ok, {{_, status, _}, _headers, _body}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sign_payload(body, secret) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end
end
```
