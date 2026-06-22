# File: `example_good_960.md`

```elixir
defmodule Events.WebhookDispatcher do
  @moduledoc """
  Dispatches domain events to registered outbound webhook endpoints,
  applying HMAC-SHA256 signatures and automatic retries with
  exponential backoff on transient failures.

  Endpoint registrations are managed externally; the dispatcher
  receives a list of endpoints per dispatch call so registration
  concerns remain in the calling context.
  """

  require Logger

  @max_attempts 4
  @base_delay_ms 500
  @request_timeout_ms 10_000
  @signature_header "x-webhook-signature"

  @type endpoint :: %{
          required(:url) => String.t(),
          required(:secret) => String.t(),
          optional(:headers) => [{String.t(), String.t()}]
        }

  @type event_payload :: map()

  @type dispatch_result :: %{
          url: String.t(),
          status: :delivered | :failed,
          attempts: pos_integer(),
          last_http_status: non_neg_integer() | nil,
          error: term() | nil
        }

  @doc """
  Dispatches `payload` to all `endpoints` concurrently.

  Each endpoint is attempted independently under a supervised Task.
  Returns one `dispatch_result` per endpoint in the same order as
  `endpoints`.
  """
  @spec dispatch([endpoint()], event_payload()) :: [dispatch_result()]
  def dispatch(endpoints, payload) when is_list(endpoints) and is_map(payload) do
    body = Jason.encode!(payload)

    endpoints
    |> Enum.map(&Task.async(fn -> dispatch_to_endpoint(&1, body) end))
    |> Enum.map(&Task.await(&1, (@max_attempts * @base_delay_ms * 8) + 5_000))
  end

  @doc """
  Dispatches `payload` to a single endpoint with retry.

  Returns a `dispatch_result` describing the outcome.
  """
  @spec dispatch_one(endpoint(), event_payload()) :: dispatch_result()
  def dispatch_one(endpoint, payload) when is_map(payload) do
    dispatch_to_endpoint(endpoint, Jason.encode!(payload))
  end

  defp dispatch_to_endpoint(%{url: url, secret: secret} = endpoint, body) do
    extra_headers = Map.get(endpoint, :headers, [])
    signature = compute_signature(body, secret)

    attempt_dispatch(url, body, signature, extra_headers, 1, nil)
  end

  defp attempt_dispatch(url, body, signature, extra_headers, attempt, _last_result)
       when attempt > @max_attempts do
    %{url: url, status: :failed, attempts: attempt - 1,
      last_http_status: nil, error: :max_attempts_exceeded}
  end

  defp attempt_dispatch(url, body, signature, extra_headers, attempt, _last) do
    headers =
      [{"content-type", "application/json"}, {@signature_header, signature}]
      ++ extra_headers

    result = post_request(url, headers, body)

    case result do
      {:ok, status} when status in 200..299 ->
        %{url: url, status: :delivered, attempts: attempt, last_http_status: status, error: nil}

      {:ok, status} when status in [429, 500, 502, 503, 504] ->
        Logger.warning("Webhook to #{url} returned #{status}, attempt #{attempt}/#{@max_attempts}")
        sleep_before_retry(attempt)
        attempt_dispatch(url, body, signature, extra_headers, attempt + 1, status)

      {:ok, status} ->
        %{url: url, status: :failed, attempts: attempt, last_http_status: status,
          error: {:non_retryable_status, status}}

      {:error, reason} ->
        Logger.warning("Webhook to #{url} failed: #{inspect(reason)}, attempt #{attempt}/#{@max_attempts}")
        sleep_before_retry(attempt)
        attempt_dispatch(url, body, signature, extra_headers, attempt + 1, nil)
    end
  end

  defp post_request(url, headers, body) do
    charlist_url = String.to_charlist(url)
    charlist_headers = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    case :httpc.request(:post, {charlist_url, charlist_headers, ~c"application/json", body},
                        [{:timeout, @request_timeout_ms}], []) do
      {:ok, {{_, status, _}, _resp_headers, _resp_body}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp compute_signature(body, secret) do
    digest = :crypto.mac(:hmac, :sha256, secret, body)
    "sha256=" <> Base.encode16(digest, case: :lower)
  end

  defp sleep_before_retry(attempt) do
    delay = @base_delay_ms * Integer.pow(2, attempt - 1)
    jitter = :rand.uniform(div(delay, 4) + 1)
    Process.sleep(delay + jitter)
  end
end
```
