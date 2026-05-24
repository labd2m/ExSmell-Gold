# Code Smell Example – Annotated

## Metadata

- **Smell name:** Inappropriate Intimacy
- **Expected smell location:** `NotificationDispatcher.dispatch/2` function
- **Affected function(s):** `NotificationDispatcher.dispatch/2`
- **Short explanation:** `NotificationDispatcher.dispatch/2` calls `Subscription.for_user/1` and `Plan.find/1` and then directly accesses internal fields of those structs (`.notify_via`, `.digest_hour`, `.tier`, `.feature_flags`) to decide routing logic. This couples the dispatcher tightly to internal details of `Subscription` and `Plan` that should be hidden behind well-defined interfaces.

---

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
    # VALIDATION: SMELL START - Inappropriate Intimacy
    # VALIDATION: This is a smell because dispatch/2 directly reads .notify_via and
    # .digest_hour from the Subscription struct, and .tier and .feature_flags from the
    # Plan struct — internal data that should be accessed through encapsulated functions
    # on Subscription and Plan, not exposed as raw fields to this module.
    subscription = Subscription.for_user(user_id)
    plan         = Plan.find(subscription.plan_id)

    channels    = subscription.notify_via
    digest_hour = subscription.digest_hour

    sms_enabled  = :sms in plan.feature_flags
    push_enabled = :push in plan.feature_flags
    is_premium   = plan.tier in [:pro, :enterprise]
    # VALIDATION: SMELL END

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

  # --- Private helpers ---

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
