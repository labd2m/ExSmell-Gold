```elixir
defmodule Notifications.SMSDispatcher do
  @moduledoc """
  Sends transactional SMS messages via Twilio. Covers OTP delivery,
  system alerts for on-call engineers, and parcel-delivery status updates
  for end customers.
  """

  require Logger

  @twilio_api_base "https://api.twilio.com/2010-04-01"
  @twilio_auth_token Application.fetch_env!(:notifications, :twilio_auth_token)

  @twilio_account_sid Application.fetch_env!(:notifications, :twilio_account_sid)

  @otp_expiry_minutes 5
  @sms_character_limit 160

  @type phone_number :: String.t()
  @type sms_result :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  Sends a one-time password to `phone_number`.

  The message automatically includes an expiry notice.

  ## Parameters
    - `phone_number` - E.164-formatted recipient number, e.g. `"+15550001234"`.
    - `otp_code` - The numeric OTP string to deliver.
  """
  @spec send_otp(phone_number(), String.t()) :: sms_result()
  def send_otp(phone_number, otp_code)
      when is_binary(phone_number) and is_binary(otp_code) do
    body = "Your verification code is #{otp_code}. It expires in #{@otp_expiry_minutes} minutes."
    Logger.info("Sending OTP SMS to=#{phone_number}")
    deliver(phone_number, body)
  end

  @doc """
  Sends an operational alert to an on-call engineer.

  ## Parameters
    - `phone_number` - Recipient's phone number in E.164 format.
    - `message` - Plain-text alert description (will be truncated if too long).
  """
  @spec send_alert(phone_number(), String.t()) :: sms_result()
  def send_alert(phone_number, message) when is_binary(phone_number) do
    truncated = truncate(message, @sms_character_limit)
    Logger.info("Sending alert SMS to=#{phone_number}")
    deliver(phone_number, "[ALERT] #{truncated}")
  end

  @doc """
  Sends a parcel-delivery status update to the recipient.

  ## Parameters
    - `phone_number` - Recipient's phone number in E.164 format.
    - `tracking_code` - The parcel tracking reference.
    - `status` - A human-readable status string, e.g. `"Out for delivery"`.
  """
  @spec send_delivery_update(phone_number(), String.t(), String.t()) :: sms_result()
  def send_delivery_update(phone_number, tracking_code, status)
      when is_binary(phone_number) do
    body = "Your parcel #{tracking_code} update: #{status}."
    Logger.info("Sending delivery SMS to=#{phone_number} tracking=#{tracking_code}")
    deliver(phone_number, body)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp deliver(to, body) do
    url = "#{@twilio_api_base}/Accounts/#{@twilio_account_sid}/Messages.json"

    payload = URI.encode_query(%{
      "To" => to,
      "From" => fetch_from_number(),
      "Body" => body
    })

    headers = [
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Authorization", basic_auth_header()}
    ]

    case HTTPoison.post(url, payload, headers, recv_timeout: 8_000) do
      {:ok, %HTTPoison.Response{status_code: code, body: resp_body}} when code in 200..201 ->
        sid = resp_body |> Jason.decode!() |> Map.get("sid", "unknown")
        Logger.info("SMS delivered message_sid=#{sid} to=#{to}")
        {:ok, sid}

      {:ok, %HTTPoison.Response{body: resp_body}} ->
        error = resp_body |> Jason.decode!() |> Map.get("message", "unknown error")
        Logger.error("SMS delivery failed to=#{to} error=#{error}")
        {:error, error}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("HTTP error delivering SMS reason=#{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  defp basic_auth_header do
    credentials = Base.encode64("#{@twilio_account_sid}:#{@twilio_auth_token}")
    "Basic #{credentials}"
  end

  defp fetch_from_number do
    Application.get_env(:notifications, :twilio_from_number, "+10000000000")
  end

  defp truncate(text, max_bytes) when byte_size(text) > max_bytes do
    String.slice(text, 0, max_bytes - 3) <> "..."
  end

  defp truncate(text, _), do: text
end
```
