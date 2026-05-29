# Annotated Example – Code Smell

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Notifications.Mailer.send_transactional_email/11` |
| **Affected function(s)** | `send_transactional_email/11` |
| **Short explanation** | Eleven arguments covering recipients, content, scheduling, and tracking options are passed individually. A `%EmailMessage{}` struct would bundle these naturally, make the signature readable, and prevent subtle mistakes such as swapping `reply_to` with `from_address`. |

```elixir
defmodule Notifications.Mailer do
  @moduledoc """
  Dispatches transactional emails through the platform's email gateway.
  Supports scheduling, tracking, and templating.
  """

  require Logger

  @max_recipients 50
  @default_priority :normal

  # VALIDATION: SMELL START - Long Parameter List
  # VALIDATION: This is a smell because the 11 parameters encode two
  # conceptual groups (message envelope and delivery options) that should
  # be a single %EmailMessage{} map/struct. Callers must carefully align
  # arguments like cc_addresses, bcc_addresses, reply_to, and from_address
  # in the right order, making mistakes easy and refactoring painful.
  def send_transactional_email(
        from_address,
        reply_to,
        to_addresses,
        cc_addresses,
        bcc_addresses,
        subject,
        html_body,
        text_body,
        send_at,
        track_opens,
        track_clicks
      ) do
    # VALIDATION: SMELL END
    with :ok <- validate_address(from_address),
         :ok <- validate_recipients(to_addresses),
         :ok <- validate_subject(subject),
         :ok <- validate_body(html_body, text_body) do
      envelope = %{
        id: generate_message_id(),
        from: from_address,
        reply_to: reply_to,
        to: to_addresses,
        cc: cc_addresses || [],
        bcc: bcc_addresses || [],
        subject: subject,
        html_body: html_body,
        text_body: text_body,
        tracking: %{opens: track_opens, clicks: track_clicks},
        scheduled_at: send_at,
        priority: @default_priority,
        queued_at: DateTime.utc_now()
      }

      case schedule_or_send(envelope) do
        {:ok, :scheduled} ->
          Logger.info("Email #{envelope.id} scheduled for #{send_at}")
          {:ok, %{message_id: envelope.id, status: :scheduled}}

        {:ok, :sent} ->
          Logger.info("Email #{envelope.id} dispatched to #{length(to_addresses)} recipient(s)")
          {:ok, %{message_id: envelope.id, status: :sent}}

        {:error, reason} ->
          Logger.error("Failed to dispatch email #{envelope.id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp validate_address(addr) do
    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, addr),
      do: :ok,
      else: {:error, "invalid from_address: #{addr}"}
  end

  defp validate_recipients(addrs) when is_list(addrs) and length(addrs) > 0 do
    cond do
      length(addrs) > @max_recipients ->
        {:error, "too many recipients (max #{@max_recipients})"}

      Enum.any?(addrs, &(not Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, &1))) ->
        {:error, "one or more invalid recipient addresses"}

      true ->
        :ok
    end
  end
  defp validate_recipients(_), do: {:error, "to_addresses must be a non-empty list"}

  defp validate_subject(s) when byte_size(s) > 0, do: :ok
  defp validate_subject(_), do: {:error, "subject must not be blank"}

  defp validate_body(html, text) when byte_size(html) > 0 or byte_size(text) > 0, do: :ok
  defp validate_body(_, _), do: {:error, "at least one of html_body or text_body is required"}

  defp schedule_or_send(%{scheduled_at: nil} = envelope) do
    deliver(envelope)
    {:ok, :sent}
  end
  defp schedule_or_send(%{scheduled_at: at} = _envelope) when not is_nil(at) do
    Logger.debug("Email enqueued for delivery at #{at}")
    {:ok, :scheduled}
  end

  defp deliver(envelope) do
    Logger.debug("Sending envelope #{envelope.id} via SMTP gateway")
    :ok
  end

  defp generate_message_id do
    rand = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    "msg-#{rand}@platform.internal"
  end
end
```
