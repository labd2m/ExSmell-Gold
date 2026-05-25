# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `NotificationDispatcher` module — functions `format_message/2`, `estimate_delivery_time/1`, and `record_dispatch_metric/2`
- **Affected functions:** `format_message/2`, `estimate_delivery_time/1`, `record_dispatch_metric/2`
- **Short explanation:** The same `case channel` branching over `:email`, `:sms`, `:push`, and `:webhook` is duplicated in three different functions. Each new notification channel requires changes in all three locations, which is the Switch Statements smell.

---

```elixir
defmodule NotificationDispatcher do
  @moduledoc """
  Dispatches notifications across multiple channels: e-mail, SMS,
  push notifications, and webhooks. Handles formatting, routing,
  delivery estimation, and metrics recording.
  """

  require Logger

  @push_max_body_chars 178
  @sms_max_body_chars 160

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching over channel
  # (:email, :sms, :push, :webhook) appears independently in format_message/2,
  # estimate_delivery_time/1, and record_dispatch_metric/2. Adding a new channel
  # forces a developer to touch all three case expressions.

  @doc """
  Formats a raw notification payload into a channel-appropriate message struct.
  """
  def format_message(channel, %{title: title, body: body} = _payload) do
    case channel do
      :email ->
        %{
          subject: title,
          html_body: "<p>#{body}</p>",
          text_body: body
        }

      :sms ->
        truncated = String.slice("#{title}: #{body}", 0, @sms_max_body_chars)
        %{text: truncated}

      :push ->
        truncated_body = String.slice(body, 0, @push_max_body_chars)
        %{title: title, body: truncated_body, badge: 1}

      :webhook ->
        %{event: "notification.sent", data: %{title: title, body: body}}
    end
  end

  @doc """
  Estimates the expected delivery window in seconds for the given channel.
  """
  def estimate_delivery_time(%{channel: channel}) do
    case channel do
      :email -> {30, 120}
      :sms -> {5, 30}
      :push -> {1, 10}
      :webhook -> {1, 5}
    end
  end

  @doc """
  Records a dispatch metric event for observability purposes.
  Returns the metric key that was emitted.
  """
  def record_dispatch_metric(%{channel: channel}, status) do
    metric_prefix =
      case channel do
        :email -> "notifications.email"
        :sms -> "notifications.sms"
        :push -> "notifications.push"
        :webhook -> "notifications.webhook"
      end

    # VALIDATION: SMELL END

    metric_key = "#{metric_prefix}.#{status}"
    :telemetry.execute([:notifications, :dispatch], %{count: 1}, %{key: metric_key})
    metric_key
  end

  @doc """
  Dispatches a notification to a single recipient on the specified channel.
  """
  def dispatch(%{channel: channel} = notification, recipient) do
    formatted = format_message(channel, notification)
    {_min_s, max_s} = estimate_delivery_time(notification)

    result = send_via_adapter(channel, formatted, recipient)

    case result do
      :ok ->
        record_dispatch_metric(notification, :success)
        Logger.info("Dispatched #{channel} notification to #{recipient.id}")
        {:ok, %{channel: channel, estimated_max_delivery_s: max_s}}

      {:error, reason} ->
        record_dispatch_metric(notification, :failure)
        Logger.error("Failed to dispatch #{channel} to #{recipient.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Dispatches a notification to multiple recipients, collecting successes and failures.
  """
  def broadcast(%{} = notification, recipients) when is_list(recipients) do
    results =
      Enum.map(recipients, fn recipient ->
        {recipient.id, dispatch(notification, recipient)}
      end)

    successes = Enum.count(results, fn {_, res} -> match?({:ok, _}, res) end)
    failures = Enum.count(results, fn {_, res} -> match?({:error, _}, res) end)

    Logger.info("Broadcast complete — success: #{successes}, failed: #{failures}")

    %{
      total: length(recipients),
      succeeded: successes,
      failed: failures,
      details: results
    }
  end

  # ---- Private helpers ----

  defp send_via_adapter(:email, payload, recipient) do
    Logger.debug("Sending email to #{recipient.email}: #{inspect(payload)}")
    :ok
  end

  defp send_via_adapter(:sms, payload, recipient) do
    Logger.debug("Sending SMS to #{recipient.phone}: #{inspect(payload)}")
    :ok
  end

  defp send_via_adapter(:push, payload, recipient) do
    Logger.debug("Sending push to device #{recipient.device_token}: #{inspect(payload)}")
    :ok
  end

  defp send_via_adapter(:webhook, payload, recipient) do
    Logger.debug("POSTing webhook to #{recipient.webhook_url}: #{inspect(payload)}")
    :ok
  end

  defp send_via_adapter(channel, _payload, _recipient) do
    {:error, {:unsupported_channel, channel}}
  end
end
```
