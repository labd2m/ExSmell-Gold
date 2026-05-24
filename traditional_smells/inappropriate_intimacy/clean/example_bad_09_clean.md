```elixir
defmodule MyApp.Notifications.NotificationDispatcher do
  @moduledoc """
  Routes outbound notifications to the appropriate delivery channel
  based on user subscription settings and plan tier.
  """

  alias MyApp.Accounts.Subscription
  alias MyApp.Plans.Plan
  alias MyApp.Notifications.{EmailSender, SmsSender, PushSender, DigestQueue}

  @supported_channels [:email, :sms, :push, :digest]

  def dispatch(user_id, notification) do
    subscription = Subscription.for_user(user_id)
    plan         = Plan.find(subscription.plan_id)

    channels    = subscription.notify_via
    digest_hour = subscription.digest_hour

    sms_enabled  = :sms in plan.feature_flags
    push_enabled = :push in plan.feature_flags
    is_premium   = plan.tier in [:pro, :enterprise]

    Enum.each(channels, fn channel ->
      cond do
        channel == :sms and not sms_enabled ->
          :ok

        channel == :push and not push_enabled ->
          :ok

        channel == :digest ->
          DigestQueue.enqueue(user_id, notification, digest_hour)

        channel == :email ->
          EmailSender.send(user_id, notification)

        channel == :sms ->
          SmsSender.send(user_id, notification)

        channel == :push ->
          PushSender.send(user_id, notification, priority: priority_for(is_premium))

        true ->
          log_unknown_channel(user_id, channel)
      end
    end)

    :ok
  end

  def broadcast(user_ids, notification) when is_list(user_ids) do
    user_ids
    |> Task.async_stream(&dispatch(&1, notification), max_concurrency: 20, timeout: 5_000)
    |> Stream.run()
  end

  def schedule(user_id, notification, deliver_at) do
    job = %{
      user_id:     user_id,
      notification: notification,
      deliver_at:  deliver_at,
      inserted_at: DateTime.utc_now()
    }
    :ets.insert(:scheduled_notifications, {user_id, deliver_at, job})
    {:ok, job}
  end

  def flush_scheduled do
    now = DateTime.utc_now()
    :ets.tab2list(:scheduled_notifications)
    |> Enum.filter(fn {_uid, deliver_at, _job} ->
      DateTime.compare(deliver_at, now) != :gt
    end)
    |> Enum.each(fn {uid, _deliver_at, job} ->
      dispatch(uid, job.notification)
      :ets.delete(:scheduled_notifications, uid)
    end)
  end


  defp priority_for(true), do: :high
  defp priority_for(false), do: :normal

  defp log_unknown_channel(user_id, channel) do
    require Logger
    Logger.warning("Unknown notification channel #{inspect(channel)} for user #{user_id}")
  end

  defp validate_notification(%{type: type, body: body})
       when is_atom(type) and is_binary(body), do: :ok
  defp validate_notification(_), do: {:error, :invalid_notification}
end
```
