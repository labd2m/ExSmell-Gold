# Annotated Example — Feature Envy

| Field                  | Value                                                                                     |
|------------------------|-------------------------------------------------------------------------------------------|
| **Smell name**         | Feature Envy                                                                              |
| **Smell location**     | `Notifications.AlertDispatcher.compose_subscriber_digest/1`                               |
| **Affected function**  | `compose_subscriber_digest/1`                                                             |
| **Explanation**        | The function calls `Subscriber.get!/1`, `Subscriber.preferences/1`, `Subscriber.active_topics/1`, `Subscriber.delivery_channels/1`, `Subscriber.digest_frequency/1`, `Subscriber.suppression_window/1`, and `Subscriber.unread_count/1`, while also reading `subscriber.locale`, `subscriber.timezone`, and `subscriber.display_name`. `AlertDispatcher` adds no alert-dispatch logic here; it only assembles a map from `Subscriber` data. The function belongs in `Subscriber`. |

```elixir
defmodule Notifications.AlertDispatcher do
  @moduledoc """
  Dispatches alerts and notifications to users and subscribers.
  """

  alias Notifications.{Subscriber, Alert, Channel, Template, DeliveryLog}
  require Logger

  @max_retry_attempts 3
  @batch_size 100

  def dispatch_alert(alert_id, recipient_ids) do
    alert = Alert.get!(alert_id)

    Enum.each(recipient_ids, fn id ->
      case send_to_recipient(alert, id) do
        {:ok, _} -> Logger.debug("Alert #{alert_id} delivered to #{id}")
        {:error, reason} -> Logger.warn("Delivery failed for #{id}: #{inspect(reason)}")
      end
    end)
  end

  def dispatch_batch(alert_id, recipient_ids) do
    recipient_ids
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(&dispatch_alert(alert_id, &1))
  end

  def retry_failed(delivery_id) do
    with {:ok, log} <- DeliveryLog.fetch(delivery_id),
         true <- log.attempts < @max_retry_attempts do
      send_to_recipient(log.alert, log.recipient_id)
    else
      false -> {:error, :max_retries_exceeded}
      err -> err
    end
  end

  def mark_as_read(alert_id, user_id) do
    DeliveryLog.update_status(alert_id, user_id, :read)
  end

  def archive_old_alerts(older_than_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -older_than_days * 86_400)
    Alert.archive_before(cutoff)
  end

  # VALIDATION: SMELL START - Feature Envy
  # VALIDATION: This is a smell because compose_subscriber_digest/1 operates almost entirely
  # VALIDATION: on the Subscriber module. It calls Subscriber.get!/1, Subscriber.preferences/1,
  # VALIDATION: Subscriber.active_topics/1, Subscriber.delivery_channels/1,
  # VALIDATION: Subscriber.digest_frequency/1, Subscriber.suppression_window/1, and
  # VALIDATION: Subscriber.unread_count/1, while also reading subscriber.locale,
  # VALIDATION: subscriber.timezone, and subscriber.display_name.
  # VALIDATION: AlertDispatcher adds no alerting logic here—it only assembles a configuration
  # VALIDATION: map from Subscriber data—making this function a better fit in Subscriber.
  def compose_subscriber_digest(subscriber_id) do
    subscriber = Subscriber.get!(subscriber_id)

    prefs = Subscriber.preferences(subscriber)
    topics = Subscriber.active_topics(subscriber)
    channels = Subscriber.delivery_channels(subscriber)
    frequency = Subscriber.digest_frequency(subscriber)
    suppression = Subscriber.suppression_window(subscriber)
    unread_count = Subscriber.unread_count(subscriber)

    send_email = :email in channels
    send_push = :push in channels
    send_sms = :sms in channels and Map.get(prefs, :sms_opt_in) == true

    now = DateTime.utc_now()

    in_suppression =
      case suppression do
        %{start: s, end: e} ->
          time = Time.from_erl!({now.hour, now.minute, now.second})
          Time.compare(time, s) in [:gt, :eq] and Time.compare(time, e) == :lt

        nil ->
          false
      end

    %{
      subscriber_id: subscriber.id,
      display_name: subscriber.display_name,
      locale: subscriber.locale,
      timezone: subscriber.timezone,
      topics: topics,
      digest_frequency: frequency,
      channels: %{email: send_email, push: send_push, sms: send_sms},
      unread_count: unread_count,
      in_suppression_window: in_suppression,
      max_per_digest: Map.get(prefs, :max_alerts_per_digest, 10),
      format: Map.get(prefs, :format, :html)
    }
  end
  # VALIDATION: SMELL END

  defp send_to_recipient(alert, recipient_id) do
    channel = Channel.preferred_for(recipient_id)
    payload = Template.render(alert, channel)
    Channel.deliver(channel, recipient_id, payload)
  end
end
```
