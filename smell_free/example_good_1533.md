```elixir
defmodule Notifications.DispatchRouter do
  @moduledoc """
  Routes outbound notifications to the appropriate delivery channel adapter.

  Supports email, SMS, and push channels. Each channel adapter conforms to
  the `ChannelAdapter` behaviour, ensuring a consistent dispatch contract
  regardless of the underlying transport.
  """

  alias Notifications.Channels.{EmailAdapter, SmsAdapter, PushAdapter}
  alias Notifications.DeliveryLog

  @type channel :: :email | :sms | :push
  @type notification :: %{
          recipient_id: String.t(),
          channel: channel(),
          subject: String.t() | nil,
          body: String.t(),
          metadata: map()
        }

  @type dispatch_result ::
          {:ok, DeliveryLog.t()}
          | {:error, :unsupported_channel}
          | {:error, :delivery_failed, String.t()}

  @doc """
  Dispatches a notification through its specified channel.

  Returns a logged delivery receipt on success, or a tagged error
  tuple describing the failure reason.
  """
  @spec dispatch(notification()) :: dispatch_result()
  def dispatch(%{channel: channel} = notification) do
    with {:ok, adapter} <- resolve_adapter(channel),
         {:ok, ref} <- adapter.deliver(notification),
         {:ok, log} <- DeliveryLog.record(notification, ref) do
      {:ok, log}
    else
      {:error, :unsupported_channel} = err -> err
      {:error, reason} -> {:error, :delivery_failed, inspect(reason)}
    end
  end

  defp resolve_adapter(:email), do: {:ok, EmailAdapter}
  defp resolve_adapter(:sms), do: {:ok, SmsAdapter}
  defp resolve_adapter(:push), do: {:ok, PushAdapter}
  defp resolve_adapter(_channel), do: {:error, :unsupported_channel}
end

defmodule Notifications.ChannelAdapter do
  @moduledoc """
  Behaviour contract for notification delivery channel adapters.
  """

  @type notification :: map()
  @type delivery_ref :: String.t()

  @callback deliver(notification()) ::
              {:ok, delivery_ref()} | {:error, term()}
end

defmodule Notifications.Channels.EmailAdapter do
  @moduledoc """
  Delivers notifications via SMTP through the configured mailer client.
  """

  @behaviour Notifications.ChannelAdapter

  @impl Notifications.ChannelAdapter
  def deliver(%{recipient_id: recipient_id, subject: subject, body: body, metadata: meta}) do
    email_address = Map.fetch!(meta, :email_address)

    Notifications.Mailer.send(%{
      to: email_address,
      subject: subject || "(No Subject)",
      text_body: body,
      headers: %{"X-Recipient-Id" => recipient_id}
    })
  end
end

defmodule Notifications.Channels.SmsAdapter do
  @moduledoc """
  Delivers notifications via SMS through the configured telephony provider.
  """

  @behaviour Notifications.ChannelAdapter

  @impl Notifications.ChannelAdapter
  def deliver(%{body: body, metadata: meta}) do
    phone_number = Map.fetch!(meta, :phone_number)
    Notifications.SmsProvider.send(phone_number, body)
  end
end

defmodule Notifications.Channels.PushAdapter do
  @moduledoc """
  Delivers mobile push notifications via the configured push gateway.
  """

  @behaviour Notifications.ChannelAdapter

  @impl Notifications.ChannelAdapter
  def deliver(%{subject: subject, body: body, metadata: meta}) do
    device_token = Map.fetch!(meta, :device_token)

    Notifications.PushGateway.send(%{
      token: device_token,
      title: subject,
      message: body
    })
  end
end
```
