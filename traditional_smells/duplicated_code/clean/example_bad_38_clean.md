```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Dispatches transactional notifications for order and shipment events.
  """

  alias Notifications.{Recipient, EmailAdapter, SmsAdapter, PushAdapter, Template}
  alias Commerce.{Order, Shipment, User}

  @supported_channels [:email, :sms, :push]
  @default_locale     "en"


  @doc """
  Sends an order-confirmation notification through the user's preferred channel.
  """
  def send_order_confirmation(%Order{} = order, %User{} = user) do
    channel =
      if user.preferred_channel in @supported_channels,
        do: user.preferred_channel,
        else: :email

    locale =
      case user.locale do
        nil -> @default_locale
        l   -> String.slice(l, 0, 2)
      end

    recipient = %Recipient{
      user_id:      user.id,
      email:        user.email,
      phone:        user.phone,
      device_token: user.device_token,
      channel:      channel,
      locale:       locale
    }

    if user.notification_opt_out? do
      {:error, :user_opted_out}
    else
      body = Template.render(:order_confirmation, %{order: order, locale: locale})
      dispatch(recipient, body)
    end
  end


  @doc """
  Sends a shipment-status update through the user's preferred channel.
  """
  def send_shipment_update(%Shipment{} = shipment, %User{} = user) do
    channel =
      if user.preferred_channel in @supported_channels,
        do: user.preferred_channel,
        else: :email

    locale =
      case user.locale do
        nil -> @default_locale
        l   -> String.slice(l, 0, 2)
      end

    recipient = %Recipient{
      user_id:      user.id,
      email:        user.email,
      phone:        user.phone,
      device_token: user.device_token,
      channel:      channel,
      locale:       locale
    }

    if user.notification_opt_out? do
      {:error, :user_opted_out}
    else
      body = Template.render(:shipment_update, %{shipment: shipment, locale: locale})
      dispatch(recipient, body)
    end
  end


  defp dispatch(%Recipient{channel: :email} = r, body) do
    EmailAdapter.deliver(%{to: r.email, body: body})
  end

  defp dispatch(%Recipient{channel: :sms} = r, body) do
    SmsAdapter.send(%{to: r.phone, text: body})
  end

  defp dispatch(%Recipient{channel: :push} = r, body) do
    PushAdapter.push(%{token: r.device_token, message: body})
  end

  defp dispatch(_recipient, _body), do: {:error, :unsupported_channel}
end
```
