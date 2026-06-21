# Annotated Example 24

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `Mailer.deliver/1` (library) and `NotificationWorker.send_confirmation/1` (client)
- **Affected function(s):** `Mailer.deliver/1`, `NotificationWorker.send_confirmation/1`
- **Short explanation:** `Mailer.deliver/1` raises exceptions for expected delivery failures such as invalid recipient addresses, suppressed contacts, and rate-limit exhaustion, without offering an `{:ok, _}/{:error, _}` alternative. The client `NotificationWorker` is forced to use `try...rescue` for what is routine notification delivery logic.

```elixir
defmodule Mailer do
  @moduledoc """
  Wraps the transactional email sending infrastructure.
  Validates addresses, checks suppression lists, and dispatches messages.
  """

  defmodule InvalidAddressError do
    defexception [:message, :address]
  end

  defmodule SuppressedRecipientError do
    defexception [:message, :address, :suppression_reason]
  end

  defmodule RateLimitError do
    defexception [:message, :retry_after_seconds]
  end

  defmodule TemplateError do
    defexception [:message, :template_id]
  end

  @suppressed_addresses MapSet.new(["bounce@example.com", "unsubscribed@example.com", "spam@example.com"])
  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because bounced addresses, unsubscribed
  # contacts, and rate limits are expected runtime conditions in any
  # notification pipeline. Raising exceptions for them without a
  # tuple-returning counterpart forces callers into try...rescue for
  # entirely predictable email delivery scenarios.
  def deliver(%{to: to, template_id: template_id, assigns: assigns} = message) do
    unless Regex.match?(@email_regex, to) do
      raise InvalidAddressError,
        message: "Recipient '#{to}' is not a valid email address",
        address: to
    end

    if MapSet.member?(@suppressed_addresses, to) do
      raise SuppressedRecipientError,
        message: "Recipient '#{to}' is on the suppression list and cannot receive email",
        address: to,
        suppression_reason: lookup_suppression_reason(to)
    end

    rendered = render_template(template_id, assigns)

    case simulate_smtp_send(to, rendered) do
      {:ok, message_id} ->
        %{
          message_id: message_id,
          to: to,
          template_id: template_id,
          delivered_at: DateTime.utc_now(),
          status: :sent
        }

      {:rate_limited, retry_after} ->
        raise RateLimitError,
          message: "SMTP rate limit reached; retry after #{retry_after}s",
          retry_after_seconds: retry_after
    end
  end

  def deliver(%{template_id: template_id}) when not is_binary(template_id) do
    raise TemplateError,
      message: "template_id must be a string, got: #{inspect(template_id)}",
      template_id: template_id
  end

  def deliver(_message) do
    raise ArgumentError, message: "Message must include :to, :template_id, and :assigns keys"
  end
  # VALIDATION: SMELL END

  defp render_template(template_id, assigns) do
    "Rendered(#{template_id}): #{inspect(assigns)}"
  end

  defp simulate_smtp_send("ratelimit@example.com", _), do: {:rate_limited, 60}
  defp simulate_smtp_send(_to, _body), do: {:ok, "msg_#{:rand.uniform(999_999)}"}

  defp lookup_suppression_reason("bounce@example.com"), do: :hard_bounce
  defp lookup_suppression_reason("unsubscribed@example.com"), do: :unsubscribed
  defp lookup_suppression_reason(_), do: :spam_complaint
end

defmodule NotificationWorker do
  @moduledoc """
  Sends transactional emails for various application events.
  """

  require Logger

  def send_confirmation(%{email: email, order_id: order_id} = context) do
    message = %{
      to: email,
      template_id: "order_confirmation_v3",
      assigns: %{
        order_id: order_id,
        customer_name: context[:customer_name] || "Customer",
        total: context[:total]
      }
    }

    # VALIDATION: SMELL START - Using exceptions for control-flow
    # VALIDATION: This is a smell because the client must use try...rescue
    # to handle foreseeable email delivery outcomes. An unsubscribed user
    # or a rate limit hit are not exceptional — they are normal operating
    # conditions in a high-volume notification system.
    try do
      receipt = Mailer.deliver(message)
      Logger.info("Order confirmation sent to #{email}, message_id=#{receipt.message_id}")
      {:ok, receipt}
    rescue
      e in Mailer.SuppressedRecipientError ->
        Logger.info("Skipping suppressed recipient #{e.address} (#{e.suppression_reason})")
        {:skip, :suppressed}

      e in Mailer.InvalidAddressError ->
        Logger.warning("Cannot send to invalid address #{e.address}")
        {:error, :invalid_address}

      e in Mailer.RateLimitError ->
        Logger.warning("Rate limited; will retry in #{e.retry_after_seconds}s")
        {:error, {:rate_limited, e.retry_after_seconds}}

      e in Mailer.TemplateError ->
        Logger.error("Template error: #{e.message}")
        {:error, :template_error}
    end
    # VALIDATION: SMELL END
  end

  def send_bulk(notifications) do
    Enum.map(notifications, &send_confirmation/1)
  end
end
```
