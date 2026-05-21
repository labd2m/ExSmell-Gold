# Annotated Example — Untested Polymorphic Behaviors

## Metadata

- **Smell name:** Untested polymorphic behaviors
- **Expected smell location:** `Notifications.Dispatcher.format_recipient/1`
- **Affected function(s):** `format_recipient/1`
- **Short explanation:** `format_recipient/1` calls `to_string/1` on whatever value is passed as
  a recipient without any guard clause or pattern matching. The intended inputs are binary email
  addresses or atoms representing internal channel names. Passing a `URI` struct silently
  produces a string that looks like an address but isn't a valid email, meaning the downstream
  mailer accepts it and sends to a garbage address. Passing a `Map` (e.g., accidentally passing
  a full user record instead of its email field) raises `Protocol.UndefinedError` at dispatch
  time, dropping the notification silently inside the rescue block.

---

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

  # VALIDATION: SMELL START - Untested polymorphic behaviors
  # VALIDATION: This is a smell because format_recipient/1 calls to_string/1
  # VALIDATION: without any guard clause, pattern match, or type restriction.
  # VALIDATION: The function is supposed to normalize a recipient value (binary
  # VALIDATION: email address, atom channel key, or phone number string) into a
  # VALIDATION: deliverable string. Passing a URI struct silently coerces it to
  # VALIDATION: its string representation, which looks like a valid address to
  # VALIDATION: the Mailer but will bounce or be rejected by the SMTP relay.
  # VALIDATION: Passing a full user Map (e.g., %User{email: "a@b.com"}) raises
  # VALIDATION: Protocol.UndefinedError, causing the entire dispatch/1 call to
  # VALIDATION: crash; the rescue in deliver_with_retry/3 swallows the error,
  # VALIDATION: silently dropping the notification and logging a confusing reason.
  defp format_recipient(recipient) do
    recipient
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end
  # VALIDATION: SMELL END

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
