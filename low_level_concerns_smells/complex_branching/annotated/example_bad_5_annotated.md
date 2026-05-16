# Code Smell Annotation

- **Smell name:** Complex branching
- **Expected smell location:** `SMSGateway.send_message/3`, the large `case` block handling every provider response
- **Affected function(s):** `send_message/3`
- **Short explanation:** A single function is responsible for all SMS delivery outcome handling: accepted, queued, invalid phone number, landline detection, carrier opt-out, content filtering, country restrictions, account balance issues, rate limits, and network errors. Each branch also triggers distinct logging and retry decisions. The resulting function has very high cyclomatic complexity and is prone to regression whenever a new provider response code is introduced.

```elixir
defmodule MyApp.Notifications.SMSGateway do
  @moduledoc """
  Client for the SMS aggregation gateway. Supports single and batch
  message delivery with delivery receipt callbacks and retry handling.
  """

  require Logger

  alias MyApp.Notifications.{DeliveryLog, PhoneRegistry, OptOutList}
  alias MyApp.Accounts.UserProfile

  @api_base "https://api.smsgateway.io/v1"
  @http_timeout_ms 8_000
  @max_message_length 1600

  @spec send_message(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom() | map()}
  def send_message(phone_number, message_body, opts \\ []) do
    sender_id = Keyword.get(opts, :sender_id, default_sender_id())
    callback_url = Keyword.get(opts, :callback_url)
    scheduled_at = Keyword.get(opts, :scheduled_at)

    headers = build_headers()

    payload = %{
      to: phone_number,
      from: sender_id,
      body: String.slice(message_body, 0, @max_message_length),
      callback_url: callback_url,
      scheduled_at: scheduled_at && DateTime.to_iso8601(scheduled_at)
    }

    body = Jason.encode!(payload)

    Logger.debug("Sending SMS to #{phone_number}")

    # VALIDATION: SMELL START - Complex branching
    # VALIDATION: This is a smell because `send_message/3` handles every possible
    # VALIDATION: SMS gateway response in a single case: accepted, queued,
    # VALIDATION: invalid/landline numbers, opt-outs, content blocks, country
    # VALIDATION: restrictions, insufficient balance, rate limits, authentication
    # VALIDATION: failures, timeouts, and generic network errors — each with its own
    # VALIDATION: logging and side effects. The cyclomatic complexity makes testing
    # VALIDATION: each path independently impractical without restructuring.
    case HTTPoison.post("#{@api_base}/messages", body, headers, recv_timeout: @http_timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        message_id = parsed["message_id"]
        DeliveryLog.record(phone_number, message_id, :sent)
        Logger.info("SMS sent: message_id=#{message_id} to=#{phone_number}")
        {:ok, %{message_id: message_id, status: :sent}}

      {:ok, %HTTPoison.Response{status_code: 202, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        message_id = parsed["message_id"]
        DeliveryLog.record(phone_number, message_id, :queued)
        Logger.info("SMS queued: message_id=#{message_id} to=#{phone_number} scheduled=#{scheduled_at}")
        {:ok, %{message_id: message_id, status: :queued}}

      {:ok, %HTTPoison.Response{status_code: 400, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)

        case parsed["error_code"] do
          "INVALID_PHONE_NUMBER" ->
            Logger.warning("SMS invalid phone number: #{phone_number}")
            PhoneRegistry.mark_invalid(phone_number)
            {:error, :invalid_phone_number}

          "LANDLINE_DETECTED" ->
            Logger.warning("SMS landline detected: #{phone_number}")
            PhoneRegistry.mark_landline(phone_number)
            {:error, :landline_number}

          "MESSAGE_TOO_LONG" ->
            Logger.warning("SMS message too long: #{byte_size(message_body)} bytes")
            {:error, :message_too_long}

          "INVALID_SENDER_ID" ->
            Logger.error("SMS invalid sender ID: #{sender_id}")
            {:error, :invalid_sender_id}

          other ->
            Logger.error("SMS bad request: error_code=#{other}")
            {:error, {:bad_request, other}}
        end

      {:ok, %HTTPoison.Response{status_code: 401}} ->
        Logger.error("SMS gateway authentication failed")
        {:error, :auth_failed}

      {:ok, %HTTPoison.Response{status_code: 402}} ->
        Logger.error("SMS account balance insufficient")
        {:error, :insufficient_balance}

      {:ok, %HTTPoison.Response{status_code: 403, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)

        case parsed["error_code"] do
          "OPT_OUT" ->
            Logger.info("SMS opt-out: #{phone_number} has opted out")
            OptOutList.record(phone_number)
            {:error, :recipient_opted_out}

          "COUNTRY_RESTRICTED" ->
            Logger.warning("SMS country restricted: #{phone_number}")
            {:error, :country_restricted}

          "CONTENT_FILTERED" ->
            Logger.warning("SMS content filtered for message to #{phone_number}")
            {:error, :content_filtered}

          _other ->
            Logger.error("SMS forbidden: #{inspect(parsed)}")
            {:error, :forbidden}
        end

      {:ok, %HTTPoison.Response{status_code: 429, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        retry_after = parsed["retry_after"] || 30
        Logger.warning("SMS rate limited, retry_after=#{retry_after}s")
        {:error, {:rate_limited, retry_after}}

      {:ok, %HTTPoison.Response{status_code: status}} when status >= 500 ->
        Logger.error("SMS gateway server error: status=#{status}")
        {:error, :gateway_unavailable}

      {:error, %HTTPoison.Error{reason: :timeout}} ->
        Logger.error("SMS gateway timeout for #{phone_number}")
        {:error, :gateway_timeout}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("SMS network error: #{inspect(reason)}")
        {:error, :network_error}
    end
    # VALIDATION: SMELL END
  end

  @spec delivery_status(String.t()) :: {:ok, map()} | {:error, atom()}
  def delivery_status(message_id) do
    headers = build_headers()

    case HTTPoison.get("#{@api_base}/messages/#{message_id}", headers, recv_timeout: @http_timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} -> {:ok, Jason.decode!(body)}
      {:ok, %HTTPoison.Response{status_code: 404}} -> {:error, :not_found}
      {:error, %HTTPoison.Error{reason: reason}} -> {:error, {:network_error, reason}}
    end
  end

  # Private helpers

  defp build_headers do
    api_key = Application.fetch_env!(:my_app, :sms_gateway_api_key)
    [{"Authorization", "Bearer #{api_key}"}, {"Content-Type", "application/json"}]
  end

  defp default_sender_id do
    Application.get_env(:my_app, :sms_default_sender, "MyApp")
  end
end
```
