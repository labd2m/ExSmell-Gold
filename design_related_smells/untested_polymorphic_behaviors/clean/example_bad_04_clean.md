```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Routes outbound notifications (email, SMS, in-app push) to the
  appropriate delivery adapter based on channel configuration.

  Supported channels: `:email`, `:sms`, `:push`, `:webhook`
  """

  require Logger

  alias Notifications.{Message, DeliveryLog}
  alias Notifications.Adapters.{Mailer, SmsSender, PushGateway, WebhookClient}

  @max_retries 3
  @retry_backoff_ms 500

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Dispatches `message` to all configured recipients.
  Returns a list of `{recipient, :ok | {:error, reason}}` tuples.
  """
  def dispatch(%Message{} = message) do
    message.recipients
    |> Enum.map(fn recipient ->
      result = deliver_with_retry(message, recipient, @max_retries)
      log_delivery(message.id, recipient, result)
      {recipient, result}
    end)
  end

  @doc """
  Dispatches to a single recipient immediately, without retry logic.
  Useful for transactional messages that must not be duplicated.
  """
  def dispatch_once(%Message{} = message, recipient) do
    deliver(message, recipient)
  end

  # ---------------------------------------------------------------------------
  # Delivery internals
  # ---------------------------------------------------------------------------

  defp deliver_with_retry(message, recipient, retries_left) do
    case deliver(message, recipient) do
      :ok ->
        :ok

      {:error, _reason} when retries_left > 0 ->
        Process.sleep(@retry_backoff_ms)
        deliver_with_retry(message, recipient, retries_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deliver(%Message{channel: :email} = message, recipient) do
    address = format_recipient(recipient)
    Mailer.send(%{to: address, subject: message.subject, body: message.body})
  end

  defp deliver(%Message{channel: :sms} = message, recipient) do
    number = format_recipient(recipient)
    SmsSender.send(%{to: number, text: message.body})
  end

  defp deliver(%Message{channel: :push} = message, recipient) do
    token = format_recipient(recipient)
    PushGateway.push(%{device_token: token, payload: message.body})
  end

  defp deliver(%Message{channel: :webhook} = message, recipient) do
    url = format_recipient(recipient)
    WebhookClient.post(url, message.body)
  end

  defp deliver(%Message{channel: unknown}, _recipient) do
    {:error, {:unknown_channel, unknown}}
  end

  defp format_recipient(recipient) do
    recipient
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  # ---------------------------------------------------------------------------
  # Logging helpers
  # ---------------------------------------------------------------------------

  defp log_delivery(message_id, recipient, :ok) do
    Logger.info("Notification #{message_id} delivered to #{inspect(recipient)}")
    DeliveryLog.record(message_id, recipient, :delivered)
  end

  defp log_delivery(message_id, recipient, {:error, reason}) do
    Logger.warning(
      "Notification #{message_id} failed for #{inspect(recipient)}: #{inspect(reason)}"
    )

    DeliveryLog.record(message_id, recipient, :failed, reason: reason)
  end

  # ---------------------------------------------------------------------------
  # Recipient validation
  # ---------------------------------------------------------------------------

  @doc "Returns true if the binary looks like a well-formed email address."
  def valid_email?(address) when is_binary(address) do
    Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, address)
  end

  def valid_email?(_), do: false
end
```
