# Annotated Example — Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `Notifications.Dispatcher.send_order_confirmation/2` and `Notifications.Dispatcher.send_shipment_update/2` |
| **Affected functions** | `send_order_confirmation/2`, `send_shipment_update/2` |
| **Short explanation** | Both functions duplicate the logic that builds the recipient struct (preferred-channel resolution, locale normalisation, opt-out check). Changing how a recipient is resolved—e.g., adding a new channel preference—requires updating two independent code paths. |

```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Dispatches transactional notifications for order and shipment events.
  """

  alias Notifications.{Recipient, EmailAdapter, SmsAdapter, PushAdapter, Template}
  alias Commerce.{Order, Shipment, User}

  @supported_channels [:email, :sms, :push]
  @default_locale     "en"

  # ---------------------------------------------------------------------------
  # Order notifications
  # ---------------------------------------------------------------------------

  @doc """
  Sends an order-confirmation notification through the user's preferred channel.
  """
  def send_order_confirmation(%Order{} = order, %User{} = user) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the recipient-building logic
    # (channel resolution, locale normalisation, opt-out check) is
    # duplicated identically in send_shipment_update/2.
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
      # VALIDATION: SMELL END
      body = Template.render(:order_confirmation, %{order: order, locale: locale})
      dispatch(recipient, body)
    end
  end

  # ---------------------------------------------------------------------------
  # Shipment notifications
  # ---------------------------------------------------------------------------

  @doc """
  Sends a shipment-status update through the user's preferred channel.
  """
  def send_shipment_update(%Shipment{} = shipment, %User{} = user) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the identical recipient-building
    # block from send_order_confirmation/2 is reproduced here. Any new
    # preference field or channel type must be added in two places.
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
      # VALIDATION: SMELL END
      body = Template.render(:shipment_update, %{shipment: shipment, locale: locale})
      dispatch(recipient, body)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

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
