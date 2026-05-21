```elixir
defmodule SmsProvider do
  @moduledoc """
  Sends SMS messages via the configured upstream gateway.
  Validates phone numbers, checks opt-out status, and enforces message limits.
  """

  defmodule InvalidPhoneNumberError do
    defexception [:message, :phone_number]
  end

  defmodule OptedOutError do
    defexception [:message, :phone_number, :opted_out_at]
  end

  defmodule MessageTooLongError do
    defexception [:message, :length, :max_length]
  end

  defmodule DeliveryFailedError do
    defexception [:message, :phone_number, :gateway_code]
  end

  @max_sms_length 160
  @e164_regex ~r/^\+[1-9]\d{6,14}$/
  @opted_out_numbers MapSet.new(["+15550001111", "+15550002222"])

  def send(phone_number, message) when not is_binary(phone_number) or phone_number == "" do
    raise InvalidPhoneNumberError,
      message: "Phone number must be a non-empty string, got: #{inspect(phone_number)}",
      phone_number: phone_number
  end

  def send(phone_number, message) do
    unless Regex.match?(@e164_regex, phone_number) do
      raise InvalidPhoneNumberError,
        message: "Phone number '#{phone_number}' is not in valid E.164 format",
        phone_number: phone_number
    end

    if MapSet.member?(@opted_out_numbers, phone_number) do
      opted_out_at = fetch_opt_out_date(phone_number)

      raise OptedOutError,
        message: "Recipient #{phone_number} has opted out of SMS communications",
        phone_number: phone_number,
        opted_out_at: opted_out_at
    end

    message_length = String.length(message)

    if message_length > @max_sms_length do
      raise MessageTooLongError,
        message:
          "Message length #{message_length} exceeds maximum of #{@max_sms_length} characters",
        length: message_length,
        max_length: @max_sms_length
    end

    case simulate_gateway(phone_number, message) do
      {:ok, sid} ->
        %{
          sid: sid,
          phone_number: phone_number,
          message_length: message_length,
          status: :sent,
          sent_at: DateTime.utc_now()
        }

      {:gateway_error, code} ->
        raise DeliveryFailedError,
          message: "Gateway rejected message to #{phone_number} with code #{code}",
          phone_number: phone_number,
          gateway_code: code
    end
  end

  defp fetch_opt_out_date("+15550001111"), do: ~U[2025-01-15 09:00:00Z]
  defp fetch_opt_out_date(_), do: ~U[2025-03-01 00:00:00Z]

  defp simulate_gateway("+15559999999", _msg), do: {:gateway_error, 30006}
  defp simulate_gateway(_phone, _msg), do: {:ok, "SM#{:rand.uniform(999_999_999)}"}
end

defmodule AlertDispatcher do
  @moduledoc """
  Dispatches real-time SMS alerts for system and operational events.
  Supports on-call escalation and bulk notification runs.
  """

  require Logger

  @max_message_chars 155

  def notify(phone_number, %{type: type, body: body} = _alert) do
    message = "[#{String.upcase(to_string(type))}] #{body}" |> String.slice(0, @max_message_chars)

    Logger.info("Dispatching #{type} alert to #{phone_number}")

    # opted-out numbers and formatting issues during bulk alert runs. These are
    # not exceptional — they are expected operational states. The client must
    # use try...rescue solely because SmsProvider.send/2 gives no other option.
    try do
      receipt = SmsProvider.send(phone_number, message)
      Logger.info("Alert sent to #{phone_number}, SID=#{receipt.sid}")
      {:ok, receipt}
    rescue
      e in SmsProvider.OptedOutError ->
        Logger.info("Skipping opted-out recipient #{e.phone_number} (opted out #{e.opted_out_at})")
        {:skip, :opted_out}

      e in SmsProvider.InvalidPhoneNumberError ->
        Logger.warning("Invalid phone number #{e.phone_number}, skipping alert")
        {:error, :invalid_phone}

      e in SmsProvider.MessageTooLongError ->
        Logger.error("Alert message too long: #{e.length}/#{e.max_length} chars")
        {:error, :message_too_long}

      e in SmsProvider.DeliveryFailedError ->
        Logger.warning("SMS delivery failed for #{e.phone_number}: gateway code #{e.gateway_code}")
        {:error, {:gateway_error, e.gateway_code}}
    end
  end

  def notify_all(recipients, alert) do
    results =
      Enum.map(recipients, fn phone ->
        {phone, notify(phone, alert)}
      end)

    sent = Enum.count(results, fn {_, r} -> match?({:ok, _}, r) end)
    skipped = Enum.count(results, fn {_, r} -> match?({:skip, _}, r) end)
    failed = Enum.count(results, fn {_, r} -> match?({:error, _}, r) end)

    Logger.info("Alert batch complete: #{sent} sent, #{skipped} skipped, #{failed} failed")
    results
  end
end
```
