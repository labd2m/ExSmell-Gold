## Metadata

- **Smell name:** Speculative Generality
- **Expected smell location:** Private function `build_push_payload/1` in `Notifications.Dispatcher`
- **Affected function(s):** `build_push_payload/1`
- **Explanation:** `build_push_payload/1` was defined speculatively to support a future push notification delivery channel (e.g., via Firebase Cloud Messaging). The system only dispatches email and in-app notifications, and no push channel was ever implemented. The function is never referenced from `deliver/2` or any other function in the module, making it unreachable dead code.

---

```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Dispatches user notifications across configured delivery channels.
  Routes each notification to email and/or in-app based on user preferences
  and the notification's type.
  """

  alias Notifications.{Notification, UserPreferences, EmailSender, InAppStore}

  @max_retries    3
  @retry_delay_ms 500

  def dispatch(%Notification{} = notification) do
    with {:ok, prefs} <- UserPreferences.fetch(notification.user_id) do
      channels = resolve_channels(notification, prefs)
      results  = Enum.map(channels, &deliver(notification, &1))
      errors   = Enum.filter(results, &match?({:error, _}, &1))

      if Enum.empty?(errors),
        do:   {:ok, :dispatched},
        else: {:partial, errors}
    end
  end

  def dispatch_batch(notifications) when is_list(notifications) do
    notifications
    |> Task.async_stream(&dispatch/1, max_concurrency: 10, timeout: 5_000)
    |> Enum.reduce({0, []}, fn
      {:ok, {:ok, :dispatched}},   {ok, err} -> {ok + 1, err}
      {:ok, {:partial, errs}},     {ok, err} -> {ok, err ++ errs}
      {:exit, reason},             {ok, err} -> {ok, err ++ [{:error, reason}]}
    end)
    |> then(fn {ok, errs} ->
      %{delivered: ok, failed: length(errs), errors: errs}
    end)
  end

  def mark_read(user_id, notification_id) do
    InAppStore.mark_read(user_id, notification_id)
  end

  def list_unread(user_id) do
    InAppStore.list_unread(user_id)
  end

  defp deliver(notification, :email) do
    payload = build_email_payload(notification)
    do_with_retry(fn -> EmailSender.send(payload) end, @max_retries)
  end

  defp deliver(notification, :in_app) do
    payload = build_in_app_payload(notification)
    InAppStore.push(notification.user_id, payload)
  end

  defp resolve_channels(%Notification{type: type}, %UserPreferences{} = prefs) do
    []
    |> then(fn ch ->
      if prefs.email_enabled? and type in prefs.email_types, do: [:email | ch], else: ch
    end)
    |> then(fn ch ->
      if prefs.in_app_enabled?, do: [:in_app | ch], else: ch
    end)
  end

  defp build_email_payload(%Notification{} = n) do
    %{
      to:      n.recipient_email,
      subject: n.subject,
      body:    n.body,
      type:    n.type,
      ref_id:  n.ref_id
    }
  end

  defp build_in_app_payload(%Notification{} = n) do
    %{
      title:      n.subject,
      body:       n.body,
      category:   to_string(n.type),
      created_at: DateTime.utc_now()
    }
  end

  # VALIDATION: SMELL START - Speculative Generality
  # VALIDATION: This is a smell because `build_push_payload/1` was added
  # speculatively to support a future push notification delivery channel
  # (e.g., Firebase Cloud Messaging or Apple APNs). In practice, push
  # notification delivery was never implemented. The function is never referenced
  # from `deliver/2` or any other function in the module. It is unreachable dead
  # code that exists solely to satisfy an anticipated future requirement that
  # never materialised.
  defp build_push_payload(%Notification{} = n) do
    %{
      title:    n.subject,
      body:     n.body,
      data: %{
        type:   to_string(n.type),
        ref_id: n.ref_id,
        url:    n.action_url
      },
      priority: "high",
      ttl:      3_600
    }
  end
  # VALIDATION: SMELL END

  defp do_with_retry(fun, retries_left) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      {:error, _} when retries_left > 0 ->
        Process.sleep(@retry_delay_ms)
        do_with_retry(fun, retries_left - 1)

      {:error, _} = err ->
        err
    end
  end
end
```
