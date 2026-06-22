```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Routes outbound notifications to the appropriate delivery channel.
  Supports email, SMS, and push notification backends via a unified dispatch API.
  """

  alias Notifications.{EmailSender, SmsSender, PushSender}

  @type channel :: :email | :sms | :push
  @type recipient :: %{email: String.t(), phone: String.t(), device_token: String.t()}
  @type notification :: %{subject: String.t(), body: String.t()}
  @type dispatch_result :: {:ok, channel()} | {:error, channel(), String.t()}

  @spec dispatch(channel(), recipient(), notification()) :: dispatch_result()
  def dispatch(:email, recipient, notification) do
    deliver_via_email(recipient, notification)
  end

  def dispatch(:sms, recipient, notification) do
    deliver_via_sms(recipient, notification)
  end

  def dispatch(:push, recipient, notification) do
    deliver_via_push(recipient, notification)
  end

  @spec broadcast([channel()], recipient(), notification()) :: [dispatch_result()]
  def broadcast(channels, recipient, notification)
      when is_list(channels) and is_map(recipient) and is_map(notification) do
    Enum.map(channels, &dispatch(&1, recipient, notification))
  end

  @spec successful_channels([dispatch_result()]) :: [channel()]
  def successful_channels(results) do
    Enum.flat_map(results, fn
      {:ok, channel} -> [channel]
      {:error, _, _} -> []
    end)
  end

  @spec deliver_via_email(recipient(), notification()) :: dispatch_result()
  defp deliver_via_email(%{email: email}, notification) do
    case EmailSender.send(email, notification.subject, notification.body) do
      :ok -> {:ok, :email}
      {:error, reason} -> {:error, :email, reason}
    end
  end

  @spec deliver_via_sms(recipient(), notification()) :: dispatch_result()
  defp deliver_via_sms(%{phone: phone}, notification) do
    case SmsSender.send(phone, notification.body) do
      :ok -> {:ok, :sms}
      {:error, reason} -> {:error, :sms, reason}
    end
  end

  @spec deliver_via_push(recipient(), notification()) :: dispatch_result()
  defp deliver_via_push(%{device_token: token}, notification) do
    case PushSender.send(token, notification.subject, notification.body) do
      :ok -> {:ok, :push}
      {:error, reason} -> {:error, :push, reason}
    end
  end
end

defmodule Notifications.DeliveryPolicy do
  @moduledoc """
  Determines which notification channels to use based on user preferences and message priority.
  """

  @type priority :: :low | :normal | :critical
  @type preference :: %{email_enabled: boolean(), sms_enabled: boolean(), push_enabled: boolean()}

  @spec resolve_channels(preference(), priority()) :: [Notifications.Dispatcher.channel()]
  def resolve_channels(preference, :critical) when is_map(preference) do
    all_enabled_channels(preference)
  end

  def resolve_channels(preference, :normal) when is_map(preference) do
    preferred_channels(preference)
  end

  def resolve_channels(preference, :low) when is_map(preference) do
    low_priority_channels(preference)
  end

  @spec all_enabled_channels(preference()) :: [Notifications.Dispatcher.channel()]
  defp all_enabled_channels(preference) do
    [:email, :sms, :push]
    |> Enum.filter(&channel_enabled?(preference, &1))
  end

  @spec preferred_channels(preference()) :: [Notifications.Dispatcher.channel()]
  defp preferred_channels(preference) do
    [:email, :push]
    |> Enum.filter(&channel_enabled?(preference, &1))
  end

  @spec low_priority_channels(preference()) :: [Notifications.Dispatcher.channel()]
  defp low_priority_channels(preference) do
    if preference.email_enabled, do: [:email], else: []
  end

  @spec channel_enabled?(preference(), Notifications.Dispatcher.channel()) :: boolean()
  defp channel_enabled?(%{email_enabled: true}, :email), do: true
  defp channel_enabled?(%{sms_enabled: true}, :sms), do: true
  defp channel_enabled?(%{push_enabled: true}, :push), do: true
  defp channel_enabled?(_, _), do: false
end
```
