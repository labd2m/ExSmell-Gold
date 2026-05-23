# Annotated Example 14 — Long Parameter List

## Metadata

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Notifications.Dispatcher.send_notification/9` |
| **Affected function(s)** | `send_notification/9` |
| **Explanation** | The function takes 9 individual parameters to describe a notification: recipient details (user_id, email, phone), content (title, body, template_id), and delivery options (channel, schedule_at, priority). These naturally form at least a `%Recipient{}` struct and a `%NotificationPayload{}` struct. The flat signature is hard to read and makes it easy to swap similarly-typed arguments. |

---

```elixir
# VALIDATION: SMELL START - Long Parameter List
# VALIDATION: This is a smell because `send_notification/9` takes nine positional
# parameters spread across three conceptual groups: who to notify (user_id,
# email, phone), what to say (title, body, template_id), and how/when to
# deliver it (channel, schedule_at, priority). Grouping these into dedicated
# structs would eliminate the risk of confusing argument positions and
# make each call site self-documenting.
defmodule Notifications.Dispatcher do
  @moduledoc """
  Routes outbound notifications across email, SMS, and push channels
  with optional scheduling and priority handling.
  """

  require Logger

  alias Notifications.Repo
  alias Notifications.Schemas.NotificationLog
  alias Notifications.Adapters.EmailAdapter
  alias Notifications.Adapters.SMSAdapter
  alias Notifications.Adapters.PushAdapter
  alias Notifications.TemplateRenderer

  @valid_channels [:email, :sms, :push]
  @valid_priorities [:low, :normal, :high, :critical]

  def send_notification(
        user_id,
        email,
        phone,
        title,
        body,
        template_id,
        channel,
        schedule_at,
        priority
      ) do
# VALIDATION: SMELL END
    with :ok <- validate_channel(channel),
         :ok <- validate_priority(priority),
         :ok <- validate_recipient(channel, email, phone) do
      rendered_body =
        if template_id do
          TemplateRenderer.render(template_id, %{title: title, body: body})
        else
          body
        end

      log_attrs = %{
        user_id: user_id,
        channel: channel,
        title: title,
        body: rendered_body,
        template_id: template_id,
        priority: priority,
        scheduled_at: schedule_at,
        status: :pending,
        inserted_at: DateTime.utc_now()
      }

      {:ok, log} = Repo.insert(NotificationLog.changeset(%NotificationLog{}, log_attrs))

      if is_nil(schedule_at) or DateTime.compare(schedule_at, DateTime.utc_now()) == :lt do
        dispatch(channel, email, phone, title, rendered_body, priority)
        Repo.update(NotificationLog.status_changeset(log, :sent))
        Logger.info("Notification #{log.id} sent via #{channel} to user #{user_id}")
        {:ok, :sent}
      else
        Logger.info("Notification #{log.id} scheduled for #{schedule_at}")
        {:ok, :scheduled}
      end
    end
  end

  defp validate_channel(channel) when channel in @valid_channels, do: :ok
  defp validate_channel(c), do: {:error, {:invalid_channel, c}}

  defp validate_priority(p) when p in @valid_priorities, do: :ok
  defp validate_priority(p), do: {:error, {:invalid_priority, p}}

  defp validate_recipient(:email, email, _phone) do
    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email || "") do
      :ok
    else
      {:error, :invalid_email}
    end
  end

  defp validate_recipient(:sms, _email, phone) do
    if Regex.match?(~r/^\+?[1-9]\d{7,14}$/, phone || "") do
      :ok
    else
      {:error, :invalid_phone}
    end
  end

  defp validate_recipient(:push, _email, _phone), do: :ok

  defp dispatch(:email, email, _phone, title, body, priority) do
    EmailAdapter.deliver(%{to: email, subject: title, body: body, priority: priority})
  end

  defp dispatch(:sms, _email, phone, _title, body, _priority) do
    SMSAdapter.send(%{to: phone, message: body})
  end

  defp dispatch(:push, _email, _phone, title, body, priority) do
    PushAdapter.push(%{title: title, body: body, priority: priority})
  end
end
```
